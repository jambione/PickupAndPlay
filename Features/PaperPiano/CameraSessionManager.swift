import Foundation
import AVFoundation
import Vision
import Combine
import CoreImage
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Finger Overlay Model

/// Isolated frame-rate publisher: only the fingertip overlay observes this, so
/// 60 Hz updates don't re-render the rest of the play screen.
final class FingerOverlayModel: ObservableObject {
    @Published var frame: OverlayFrame?
}

// MARK: - Camera Session Manager

class CameraSessionManager: NSObject, ObservableObject {

    // MARK: Published

    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var isRunning = false
    @Published var isAuthorized = false
    @Published var calibration = KeyboardCalibration()
    @Published var activeNotes: [ActiveNote] = []
    @Published var detectedCorners: [CGPoint] = []   // QR corner markers found by Vision
    @Published var calibrationState: CalibrationState = .idle
    @Published var authStatus: CameraAuthStatus = .unknown
    @Published var zoomFactor: CGFloat = 1.0

    /// Frame-rate fingertip positions for the camera overlay (separate publisher).
    let overlayModel = FingerOverlayModel()

    enum CalibrationState {
        case idle
        case scanning           // looking for corner markers
        case aligned            // found all 4 corners, ready to confirm
        case calibrated         // user confirmed, ready to play
    }

    enum CameraAuthStatus: String {
        case unknown, requesting, authorized, denied, restricted
    }

    // MARK: Private

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.tapnote.camera", qos: .userInteractive)
    private var captureDevice: AVCaptureDevice?
    #if !targetEnvironment(macCatalyst)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    #endif

    // Vision requests
    private var handPoseRequest = VNDetectHumanHandPoseRequest()
    private var barcodeRequest = VNDetectBarcodesRequest()

    // Debounce rapid note triggers (manual taps only)
    private var lastNoteTime: [Int: Date] = [:]
    private let noteDebounce: TimeInterval = 0.15

    // MARK: Video-queue-owned state
    // The video queue owns the calibration used for hit-testing plus the set of
    // sounding keys, so the finger→audio path never waits on the main thread.
    // (`calibration` above is the display copy for taps/overlays.)
    private var liveCalibration = KeyboardCalibration()
    private var isCalibratedOnVideoQueue = false
    private var pressedKeyIDs: Set<Int> = []
    private var frameIndex = 0

    /// QR re-detection cadence once calibrated (every Nth frame ≈ 10 Hz at 60 fps —
    /// plenty, since corner smoothing low-passes anyway). Scanning runs every frame.
    private let qrFrameStride = 6

    // MARK: Press detection (camera hand-tracking)

    /// A fingertip tracked across frames. A camera can't see the *depth* of a press
    /// on flat paper, so we treat "fingertip settled over a key" as the trigger:
    /// a note fires when a finger lands on a new key (edge-triggered), and releases
    /// when it moves off, changes keys, or lifts out of frame.
    private struct TrackedFinger {
        var id: Int
        var history: [(pt: CGPoint, t: TimeInterval)]  // oldest→newest, time-bounded
        var pressedKeyID: Int?     // the key this finger is currently sounding, if any
        var candidateKeyID: Int?   // key seen under the finger this frame (pending confirm)
        var candidateCount: Int    // consecutive frames the candidate has held
        var lastSeen: TimeInterval
    }

    private var trackedFingers: [TrackedFinger] = []
    private var nextFingerID = 0

    // Tunables — normalized image units (0…1). Need on-device tuning.
    private let assocRadius: Double = 0.09         // max fingertip travel between frames to be "the same finger"
    private let keyConfirmFrames = 2               // frames a finger must hold a key before it sounds (debounces boundary flicker)
    private let historySpan: TimeInterval = 0.18
    private let fingerTimeout: TimeInterval = 0.25

    // MARK: - Lifecycle

    func start() {
        checkAuthorization()
    }

    func stop() {
        session.stopRunning()
        DispatchQueue.main.async { self.isRunning = false }
    }

    // MARK: - Authorization

    private func checkAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("📷 authorizationStatus = \(status.rawValue)")
        switch status {
        case .authorized:
            authStatus = .authorized
            isAuthorized = true
            setupSession()
        case .notDetermined:
            authStatus = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    print("📷 requestAccess granted = \(granted)")
                    self?.authStatus = granted ? .authorized : .denied
                    self?.isAuthorized = granted
                    if granted { self?.setupSession() }
                }
            }
        case .denied:
            authStatus = .denied
            isAuthorized = false
        case .restricted:
            authStatus = .restricted
            isAuthorized = false
        @unknown default:
            authStatus = .unknown
            isAuthorized = false
        }
    }

    // MARK: - Zoom

    /// Sets the camera zoom (1× = no zoom), clamped to the device's supported range.
    func setZoom(_ factor: CGFloat) {
        guard let device = captureDevice else { return }
        let maxZoom = min(6.0, device.maxAvailableVideoZoomFactor)
        let clamped = max(1.0, min(factor, maxZoom))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = clamped }
        } catch {
            print("zoom error: \(error)")
        }
    }

    /// Opens the system Settings page for this app (to toggle camera access).
    func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    // MARK: - Session Setup

    /// Target capture rate. Drop to 30 if 60 proves too heavy thermally.
    private let targetFrameRate = 60.0

    /// Smallest ≥720p format that supports `targetFrameRate` — high frame rate
    /// without paying for pixels Vision doesn't need.
    private func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestPixels = Int.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.height >= 720, dims.height <= 1080 else { continue }
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= targetFrameRate })
            else { continue }
            let pixels = Int(dims.width) * Int(dims.height)
            if pixels < bestPixels { bestPixels = pixels; best = format }
        }
        return best
    }

    private func setupSession() {
        session.beginConfiguration()

        // Input — prefer back camera on iOS, built-in on Mac
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        captureDevice = device
        if session.canAddInput(input) { session.addInput(input) }

        // High frame rate: pick a 60 fps-capable format where available
        // (.inputPriority so the preset doesn't override it); else 720p default.
        if let format = bestFormat(for: device),
           (try? device.lockForConfiguration()) != nil {
            session.sessionPreset = .inputPriority
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("📷 capture format: \(dims.width)x\(dims.height) @ \(Int(targetFrameRate))fps")
        } else {
            session.sessionPreset = .hd1280x720
            print("📷 capture format: 1280x720 @ default fps (no 60fps format)")
        }

        // Output
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()

        // Preview layer
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        DispatchQueue.main.async {
            self.previewLayer = layer
            #if !targetEnvironment(macCatalyst)
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                device: device, previewLayer: layer)
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.addObserver(
                self, selector: #selector(self.orientationChanged),
                name: UIDevice.orientationDidChangeNotification, object: nil)
            self.applyRotation()
            #endif
        }

        // Configure Vision requests. Use the newest hand-pose model available
        // (revert to VNDetectHumanHandPoseRequestRevision1 if it regresses).
        handPoseRequest.maximumHandCount = 2
        handPoseRequest.revision = VNDetectHumanHandPoseRequest.supportedRevisions.max()
            ?? VNDetectHumanHandPoseRequestRevision1
        barcodeRequest.symbologies = [.qr]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async { self?.isRunning = true }
        }
    }

    // MARK: - Orientation

    #if !targetEnvironment(macCatalyst)
    @objc private func orientationChanged() { applyRotation() }

    /// Keeps the preview and the delivered frames upright for the current device
    /// orientation, so both portrait and landscape work and detection stays aligned.
    private func applyRotation() {
        guard let coordinator = rotationCoordinator else { return }
        if let previewConn = previewLayer?.connection {
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if previewConn.isVideoRotationAngleSupported(angle) {
                previewConn.videoRotationAngle = angle
            }
        }
        if let outputConn = videoOutput.connection(with: .video) {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if outputConn.isVideoRotationAngleSupported(angle) {
                outputConn.videoRotationAngle = angle
            }
        }
    }
    #endif

    // MARK: - Calibration (single write funnel)

    /// The only way calibration corners are set from outside the video queue.
    /// Updates the main-thread display copy and mirrors into the video-queue-owned
    /// copy used for hit-testing.
    func setCalibrationCorners(_ corners: [CGPoint]) {
        calibration.setCorners(corners)
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.liveCalibration.setCorners(corners)
            self.isCalibratedOnVideoQueue = corners.count == 4
        }
    }

    func resetCalibration() {
        calibration = KeyboardCalibration()
        calibrationState = .idle
        detectedCorners = []
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.liveCalibration = KeyboardCalibration()
            self.isCalibratedOnVideoQueue = false
            self.trackedFingers.removeAll()
            for id in self.pressedKeyIDs {
                if let key = PaperPianoKey.byID[id] { PianoAudioEngine.shared.stopNote(key: key) }
            }
            self.pressedKeyIDs.removeAll()
            DispatchQueue.main.async { self.activeNotes.removeAll() }
        }
    }

    func confirmAutoCalibration() {
        setCalibrationCorners(detectedCorners)
        calibrationState = .calibrated
    }

    // MARK: - Manual Tap (fallback input)

    func handleTap(at previewPoint: CGPoint, previewSize: CGSize) {
        guard calibration.isCalibrated else { return }
        if let key = calibration.key(at: previewPoint, previewSize: previewSize) {
            triggerKey(key, velocity: 0.85)
        }
    }

    // MARK: - Note Triggering

    func triggerKey(_ key: PaperPianoKey, velocity: Float = 0.8) {
        let now = Date()
        if let last = lastNoteTime[key.id], now.timeIntervalSince(last) < noteDebounce { return }
        lastNoteTime[key.id] = now

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Remove existing note for this key if re-triggered
            self.activeNotes.removeAll { $0.key.id == key.id }
            let note = ActiveNote(key: key, startTime: now, velocity: velocity)
            self.activeNotes.append(note)
            PianoAudioEngine.shared.playNote(key: key, velocity: velocity)

            // Auto-release after 1.5 seconds (simulated key lift)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.activeNotes.removeAll { $0.key.id == key.id }
            }
        }
    }

    // MARK: - Vision Processing

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameIndex &+= 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up, options: [:])

        // QR corner detection runs every frame while scanning, but only every Nth
        // frame once calibrated — the keyboard barely moves and smoothing covers it.
        let runQR = !isCalibratedOnVideoQueue || frameIndex % qrFrameStride == 0
        try? handler.perform(runQR ? [handPoseRequest, barcodeRequest] : [handPoseRequest])

        processHandPose()
        if runQR { detectQRCorners(barcodeRequest.results ?? []) }
    }

    private func processHandPose() {
        guard isCalibratedOnVideoQueue else { return }
        guard let observations = handPoseRequest.results, !observations.isEmpty else {
            handleNoFingers()
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        var fingerTips: [CGPoint] = []

        for observation in observations {
            let tips: [VNHumanHandPoseObservation.JointName] = [
                .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip
            ]
            for tipName in tips {
                guard let point = try? observation.recognizedPoint(tipName),
                      point.confidence > 0.5 else { continue }
                // VNPoint has y-flipped (0=bottom), convert to standard UIKit/normalized
                fingerTips.append(CGPoint(x: point.location.x, y: 1 - point.location.y))
            }
        }

        updateTracking(with: fingerTips, now: now)
        publishOverlay(timestamp: now)
    }

    /// One coalesced main-thread publish per frame, consumed only by the overlay view.
    private func publishOverlay(timestamp: TimeInterval) {
        let dots = trackedFingers.compactMap { finger -> FingerDot? in
            guard let pt = finger.history.last?.pt else { return nil }
            return FingerDot(id: finger.id, location: pt, isPressed: finger.pressedKeyID != nil)
        }
        let frame = OverlayFrame(fingers: dots, timestamp: timestamp)
        DispatchQueue.main.async { [weak self] in self?.overlayModel.frame = frame }
    }

    // MARK: - Finger Tracking & Press Detection

    /// No hands in frame: release everything and forget tracked fingers.
    private func handleNoFingers() {
        guard !trackedFingers.isEmpty else { return }
        for finger in trackedFingers where finger.pressedKeyID != nil {
            releaseKey(finger.pressedKeyID!)
        }
        trackedFingers.removeAll()
        DispatchQueue.main.async { [weak self] in self?.overlayModel.frame = nil }
    }

    /// Associates this frame's fingertips with existing tracked fingers (nearest
    /// neighbour), spawns new ones, evaluates press/release, and prunes stale fingers.
    private func updateTracking(with tips: [CGPoint], now: TimeInterval) {
        var usedTip = Array(repeating: false, count: tips.count)

        // 1. Extend existing tracks with their nearest unused tip.
        for i in trackedFingers.indices {
            guard let last = trackedFingers[i].history.last?.pt else { continue }
            var best = -1
            var bestDist = assocRadius
            for (j, tip) in tips.enumerated() where !usedTip[j] {
                let d = distance(tip, last)
                if d < bestDist { bestDist = d; best = j }
            }
            if best >= 0 {
                usedTip[best] = true
                appendHistory(&trackedFingers[i], pt: tips[best], t: now)
                trackedFingers[i].lastSeen = now
                evaluatePress(&trackedFingers[i])
            }
        }

        // 2. Any leftover tips become newly tracked fingers.
        for (j, tip) in tips.enumerated() where !usedTip[j] {
            trackedFingers.append(TrackedFinger(id: nextFingerID,
                                                history: [(tip, now)],
                                                pressedKeyID: nil,
                                                candidateKeyID: nil,
                                                candidateCount: 0,
                                                lastSeen: now))
            nextFingerID += 1
        }

        // 3. Drop fingers we haven't seen recently, releasing any note they held.
        trackedFingers.removeAll { finger in
            let stale = now - finger.lastSeen > fingerTimeout
            if stale, let keyID = finger.pressedKeyID { releaseKey(keyID) }
            return stale
        }
    }

    private func appendHistory(_ finger: inout TrackedFinger, pt: CGPoint, t: TimeInterval) {
        finger.history.append((pt, t))
        while finger.history.count > 2, let first = finger.history.first, t - first.t > historySpan {
            finger.history.removeFirst()
        }
        if finger.history.count > 8 { finger.history.removeFirst(finger.history.count - 8) }
    }

    /// A camera can't measure a press's *depth* on flat paper, so we trigger on
    /// position: the note under a fingertip sounds once the finger has held that key
    /// for `keyConfirmFrames` (which debounces flicker at key boundaries and brief
    /// mis-detections). Moving onto a different key retriggers; moving off any key or
    /// lifting out of frame releases.
    private func evaluatePress(_ finger: inout TrackedFinger) {
        guard let pt = finger.history.last?.pt else { return }
        let key = liveCalibration.key(at: pt, previewSize: CGSize(width: 1, height: 1))
        let currentKeyID = key?.id

        // Confirm the key is stable for a couple of frames before acting on it.
        if currentKeyID == finger.candidateKeyID {
            finger.candidateCount += 1
        } else {
            finger.candidateKeyID = currentKeyID
            finger.candidateCount = 1
        }
        guard finger.candidateCount >= keyConfirmFrames else { return }

        // Edge trigger: only act when the confirmed key differs from what's sounding.
        guard finger.candidateKeyID != finger.pressedKeyID else { return }
        if let old = finger.pressedKeyID { releaseKey(old) }
        finger.pressedKeyID = nil
        if let key, key.id == finger.candidateKeyID {
            pressKey(key, velocity: 0.8)
            finger.pressedKeyID = key.id
        }
    }

    private func distance(_ p: CGPoint, _ q: CGPoint) -> Double {
        Double(hypot(p.x - q.x, p.y - q.y))
    }

    /// Note-on for a sustained press (held until `releaseKey`). Audio fires
    /// directly from the video queue — no main-thread hop in the sound path.
    private func pressKey(_ key: PaperPianoKey, velocity: Float) {
        guard !pressedKeyIDs.contains(key.id) else { return }
        pressedKeyIDs.insert(key.id)
        PianoAudioEngine.shared.holdNote(key: key, velocity: velocity)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeNotes.removeAll { $0.key.id == key.id }
            self.activeNotes.append(ActiveNote(key: key, startTime: Date(), velocity: velocity))
        }
    }

    /// Note-off for a previously pressed key.
    private func releaseKey(_ keyID: Int) {
        guard pressedKeyIDs.remove(keyID) != nil else { return }
        if let key = PaperPianoKey.byID[keyID] {
            PianoAudioEngine.shared.stopNote(key: key)
        }
        DispatchQueue.main.async { [weak self] in
            self?.activeNotes.removeAll { $0.key.id == keyID }
        }
    }

    // MARK: - Orange Corner-Marker Detection (calibration)

    private var cornerStableCount = 0

    /// Locates the keyboard from the four corner QR codes. Each QR encodes its
    /// corner ("TAPNOTE:TL/TR/BL/BR"), so detection is unambiguous and robust to
    /// lighting and angle — Vision returns each code's position directly.
    private func detectQRCorners(_ results: [VNBarcodeObservation]) {
        var found: [String: CGPoint] = [:]
        for obs in results {
            guard let payload = obs.payloadStringValue,
                  payload.hasPrefix("TAPNOTE:") else { continue }
            // boundingBox is normalized with a bottom-left origin — flip Y to match
            // the fingertip coordinate space.
            let center = CGPoint(x: obs.boundingBox.midX, y: 1 - obs.boundingBox.midY)
            found[String(payload.dropFirst("TAPNOTE:".count))] = center
        }
        guard let tl = found["TL"], let tr = found["TR"],
              let bl = found["BL"], let br = found["BR"] else { markersLost(); return }
        markersFound([tl, tr, bl, br])
    }

    private func markersFound(_ corners: [CGPoint]) {
        cornerStableCount += 1
        let stable = cornerStableCount

        if isCalibratedOnVideoQueue {
            // Live re-calibration on the video queue: follow the paper as the
            // phone/paper moves. Reject jumps (occlusion / false positives) and
            // low-pass smooth, then mirror the display copy to the main thread.
            let old = liveCalibration.corners
            let smoothed: [CGPoint]
            if old.count == 4 {
                let sane = zip(old, corners).allSatisfy {
                    hypot($0.x - $1.x, $0.y - $1.y) < 0.2
                }
                guard sane else { return }
                smoothed = zip(old, corners).map {
                    CGPoint(x: 0.6 * $0.x + 0.4 * $1.x,
                            y: 0.6 * $0.y + 0.4 * $1.y)
                }
            } else {
                smoothed = corners
            }
            liveCalibration.setCorners(smoothed)
            DispatchQueue.main.async { [weak self] in
                self?.calibration.setCorners(smoothed)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detectedCorners = corners
            // Require a few consistent frames before offering to confirm.
            if stable >= 3, self.calibrationState == .idle || self.calibrationState == .scanning {
                self.calibrationState = .aligned
            } else if self.calibrationState == .idle {
                self.calibrationState = .scanning
            }
        }
    }

    private func markersLost() {
        cornerStableCount = 0
        // While calibrated, a missed detection just means the corners hold their
        // last smoothed position — nothing to publish.
        guard !isCalibratedOnVideoQueue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.calibrationState == .aligned || self.calibrationState == .scanning {
                self.calibrationState = .scanning
                self.detectedCorners = []
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        processFrame(sampleBuffer)
    }
}
