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

    /// Per-corner registration feedback: marker name (TL/TR/BL/BR) → normalized
    /// center, for every QR currently seen. Lets the UI highlight each recognized
    /// corner individually and show which ones are still missing.
    @Published var foundMarkers: [String: CGPoint] = [:]

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
    private var rotationObservations: [NSKeyValueObservation] = []
    private let noteHaptic = UIImpactFeedbackGenerator(style: .light)
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

    /// Stable identity for one of up to 10 fingers: which hand slot + which joint.
    /// Vision names each joint per hand, so identity comes free — no positional
    /// re-association between fingers, which is what makes chords reliable.
    private struct FingerKey: Hashable {
        let handSlot: Int
        let joint: VNHumanHandPoseObservation.JointName
    }

    /// A hand followed across frames by centroid continuity (not chirality, which
    /// Vision can flip or report unknown — position is the stable signal).
    private struct HandTrack {
        var centroid: CGPoint
        var lastSeen: TimeInterval
    }

    private static let tipJoints: [VNHumanHandPoseObservation.JointName] = [
        .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip
    ]

    private var handTracks: [Int: HandTrack] = [:]        // slot (0/1) → track
    private var fingers: [FingerKey: TrackedFinger] = [:] // ≤ 10 entries

    // Tunables — normalized image units (0…1). Need on-device tuning.
    private let handAssocRadius: Double = 0.3      // max hand-centroid travel between frames
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
            // KVO on the coordinator's angles tracks the device's *physical*
            // rotation continuously (gravity-based) — smoother than UIDevice
            // orientation notifications, and it works under orientation lock.
            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: device, previewLayer: layer)
            self.rotationCoordinator = coordinator
            self.rotationObservations = [
                coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                    options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.applyRotation() }
                },
                coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                    options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.applyRotation() }
                },
            ]
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
        foundMarkers = [:]
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.liveCalibration = KeyboardCalibration()
            self.isCalibratedOnVideoQueue = false
            self.scanCorners = []
            self.alignedSince = nil
            self.fingers.removeAll()
            self.handTracks.removeAll()
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
        foundMarkers = [:]
        detectedCorners = []
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
        if runQR {
            detectQRCorners(barcodeRequest.results ?? [],
                            now: Date().timeIntervalSinceReferenceDate)
        }
    }

    private func processHandPose() {
        guard isCalibratedOnVideoQueue else { return }
        guard let observations = handPoseRequest.results, !observations.isEmpty else {
            handleNoFingers()
            return
        }

        let now = Date().timeIntervalSinceReferenceDate

        // Extract each hand's visible tips (y-flipped to top-left origin).
        var hands: [(tips: [(joint: VNHumanHandPoseObservation.JointName, pt: CGPoint)],
                     centroid: CGPoint)] = []
        for observation in observations {
            var tips: [(VNHumanHandPoseObservation.JointName, CGPoint)] = []
            var sum = CGPoint.zero
            for joint in Self.tipJoints {
                guard let point = try? observation.recognizedPoint(joint),
                      point.confidence > 0.5 else { continue }
                let pt = CGPoint(x: point.location.x, y: 1 - point.location.y)
                tips.append((joint, pt))
                sum.x += pt.x; sum.y += pt.y
            }
            guard !tips.isEmpty else { continue }
            let centroid = CGPoint(x: sum.x / CGFloat(tips.count),
                                   y: sum.y / CGFloat(tips.count))
            hands.append((tips, centroid))
        }

        // Assign each observed hand to a persistent slot by centroid continuity,
        // then upsert its fingers under their (slot, joint) identity.
        for hand in hands {
            let slot = assignHandSlot(centroid: hand.centroid, now: now)
            handTracks[slot] = HandTrack(centroid: hand.centroid, lastSeen: now)
            for (joint, pt) in hand.tips {
                let key = FingerKey(handSlot: slot, joint: joint)
                var finger = fingers[key] ?? TrackedFinger(
                    id: stableID(for: key), history: [], pressedKeyID: nil,
                    candidateKeyID: nil, candidateCount: 0, lastSeen: now)
                appendHistory(&finger, pt: pt, t: now)
                finger.lastSeen = now
                evaluatePress(&finger)
                fingers[key] = finger
            }
        }

        pruneStaleFingers(now: now)
        publishOverlay(timestamp: now)
    }

    /// Nearest existing hand track within `handAssocRadius`, else a free slot,
    /// else the stalest slot (Vision reports at most 2 hands).
    private func assignHandSlot(centroid: CGPoint, now: TimeInterval) -> Int {
        var best: Int?
        var bestDist = handAssocRadius
        for (slot, track) in handTracks {
            let d = distance(centroid, track.centroid)
            if d < bestDist { bestDist = d; best = slot }
        }
        if let best { return best }
        for slot in 0...1 where handTracks[slot] == nil { return slot }
        return handTracks.min { $0.value.lastSeen < $1.value.lastSeen }?.key ?? 0
    }

    /// Stable overlay/debug id: slot × 10 + joint index.
    private func stableID(for key: FingerKey) -> Int {
        key.handSlot * 10 + (Self.tipJoints.firstIndex(of: key.joint) ?? 9)
    }

    /// Drops fingers (and hands) not seen recently, releasing any notes they held.
    /// A finger briefly losing confidence keeps its identity until the timeout, so
    /// it can't get re-associated to a neighbour and retrigger.
    private func pruneStaleFingers(now: TimeInterval) {
        for (key, finger) in fingers where now - finger.lastSeen > fingerTimeout {
            if let keyID = finger.pressedKeyID { releaseKey(keyID) }
            fingers.removeValue(forKey: key)
        }
        for (slot, track) in handTracks where now - track.lastSeen > fingerTimeout {
            handTracks.removeValue(forKey: slot)
        }
    }

    /// One coalesced main-thread publish per frame, consumed only by the overlay view.
    private func publishOverlay(timestamp: TimeInterval) {
        let dots = fingers.values.compactMap { finger -> FingerDot? in
            guard let pt = finger.history.last?.pt else { return nil }
            return FingerDot(id: finger.id, location: pt, isPressed: finger.pressedKeyID != nil)
        }
        let frame = OverlayFrame(fingers: dots, timestamp: timestamp)
        DispatchQueue.main.async { [weak self] in self?.overlayModel.frame = frame }
    }

    // MARK: - Finger Tracking & Press Detection

    /// No hands in frame: release everything and forget tracked fingers.
    private func handleNoFingers() {
        guard !fingers.isEmpty || !handTracks.isEmpty else { return }
        for finger in fingers.values where finger.pressedKeyID != nil {
            releaseKey(finger.pressedKeyID!)
        }
        fingers.removeAll()
        handTracks.removeAll()
        DispatchQueue.main.async { [weak self] in self?.overlayModel.frame = nil }
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
            pressKey(key, velocity: arrivalVelocity(of: finger))
            finger.pressedKeyID = key.id
        }
    }

    /// Expressive dynamics: a fast strike lands loud, a gentle placement soft.
    /// Speed is measured across the finger's recent history (normalized units/s).
    private func arrivalVelocity(of finger: TrackedFinger) -> Float {
        guard let first = finger.history.first, let last = finger.history.last,
              last.t - first.t > 0.01 else { return 0.7 }
        let speed = distance(last.pt, first.pt) / (last.t - first.t)
        return Float(min(1.0, 0.45 + speed * 1.2))
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
            #if !targetEnvironment(macCatalyst)
            self.noteHaptic.impactOccurred()
            #endif
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

    // MARK: - QR Corner-Marker Detection (calibration)

    // Video-queue-owned registration state.
    private var scanCorners: [CGPoint] = []          // smoothed outline while registering
    private var alignedSince: TimeInterval?          // when all 4 corners became stable
    private var lastFullDetection: TimeInterval = 0  // last frame with all 4 markers

    /// All 4 corners must hold steady this long before the state advances to
    /// .aligned (the "short delay confirming recognition").
    private let alignStability: TimeInterval = 0.5
    /// Missed detections shorter than this don't bounce the UI back to scanning —
    /// the single-frame flicker that made registration feel jittery.
    private let markerGrace: TimeInterval = 0.4

    /// Locates the keyboard from the four corner QR codes. Each QR encodes its
    /// corner ("TAPNOTE:TL/TR/BL/BR"), so detection is unambiguous and robust to
    /// lighting and angle — Vision returns each code's position directly.
    private func detectQRCorners(_ results: [VNBarcodeObservation], now: TimeInterval) {
        var found: [String: CGPoint] = [:]
        for obs in results {
            guard let payload = obs.payloadStringValue,
                  payload.hasPrefix("TAPNOTE:") else { continue }
            // boundingBox is normalized with a bottom-left origin — flip Y to match
            // the fingertip coordinate space.
            let center = CGPoint(x: obs.boundingBox.midX, y: 1 - obs.boundingBox.midY)
            found[String(payload.dropFirst("TAPNOTE:".count))] = center
        }

        // Per-marker feedback while registering: highlight each recognized corner.
        if !isCalibratedOnVideoQueue {
            DispatchQueue.main.async { [weak self] in self?.foundMarkers = found }
        }

        if let tl = found["TL"], let tr = found["TR"],
           let bl = found["BL"], let br = found["BR"] {
            markersFound([tl, tr, bl, br], now: now)
        } else {
            markersMissing(now: now)
        }
    }

    private func markersFound(_ corners: [CGPoint], now: TimeInterval) {
        lastFullDetection = now

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

        // Registering: smooth the outline the same way so it doesn't jitter, and
        // restart the stability clock on any big jump (camera swung elsewhere).
        if scanCorners.count == 4,
           zip(scanCorners, corners).allSatisfy({ hypot($0.x - $1.x, $0.y - $1.y) < 0.2 }) {
            scanCorners = zip(scanCorners, corners).map {
                CGPoint(x: 0.6 * $0.x + 0.4 * $1.x, y: 0.6 * $0.y + 0.4 * $1.y)
            }
        } else {
            scanCorners = corners
            alignedSince = now
        }
        if alignedSince == nil { alignedSince = now }

        let stable = now - (alignedSince ?? now) >= alignStability
        let outline = scanCorners
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detectedCorners = outline
            if stable, self.calibrationState == .idle || self.calibrationState == .scanning {
                self.calibrationState = .aligned
            } else if self.calibrationState == .idle {
                self.calibrationState = .scanning
            }
        }
    }

    private func markersMissing(now: TimeInterval) {
        // While calibrated, a missed detection just means the corners hold their
        // last smoothed position — nothing to publish.
        guard !isCalibratedOnVideoQueue else { return }
        // Grace period: brief dropouts keep the current outline and state.
        guard now - lastFullDetection > markerGrace else { return }
        guard !scanCorners.isEmpty || alignedSince != nil else { return }
        scanCorners = []
        alignedSince = nil
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
