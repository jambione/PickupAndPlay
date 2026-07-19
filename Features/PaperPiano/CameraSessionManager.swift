import Foundation
import AVFoundation
import Vision
import Combine
import CoreImage
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Auto-Frame Hint

/// What auto-frame is doing / needs from the user during registration.
enum AutoFrameHint: Equatable {
    case zoomingOut                                  // widening to find more corners
    case zoomingIn                                   // tightening on the found keyboard
    case aimToward(corners: [String], estimate: CGPoint?)  // camera must be aimed; estimate = predicted spot (normalized) if known
    case searchWider                                 // already at widest — reposition the phone
}

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

    /// Which printed sheet is active (auto-detected from the QR payloads).
    @Published var activeVariant: KeyboardVariant = .threeOctave

    /// What auto-frame is currently doing (nil = idle/satisfied).
    @Published var autoFrameHint: AutoFrameHint?

    /// True after a manual pinch pauses auto-framing (resumable).
    @Published var autoFramePaused = false

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
    private var currentVariantVQ: KeyboardVariant = .threeOctave
    private var pressedKeyIDs: Set<Int> = []
    private var frameIndex = 0

    /// Presentation timestamp (host clock, seconds) of the frame being processed
    /// right now — read only by LatencyProbe to time first-contact → note-on.
    private var currentFramePresentationTime: Double = 0

    /// QR re-detection cadence once calibrated (every Nth frame ≈ 5 Hz at 60 fps —
    /// plenty, since corner smoothing low-passes anyway). Scanning runs every frame.
    /// Kept sparse deliberately: the barcode pass is the per-frame cost spike, and
    /// measured effective fps was 48/60 with it at every 6th frame.
    private let qrFrameStride = 12

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
        var candidateContactTime: TimeInterval = 0  // host-clock presentation time of first sighting on this candidate (LatencyProbe)
        // Lift-release state: the key this finger lift-released and must depart
        // (or visibly re-settle on) before it may sound again, plus the settle
        // counter and when the current press started (guards the approach tail).
        var awaitingDepartureFrom: Int? = nil
        var departureSettleCount: Int = 0
        var pressStartTime: TimeInterval = 0
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
    private let keyConfirmFrames = 3               // frames a finger must hold a key before it sounds (debounces boundary flicker)
    // ^ THE accuracy↔latency dial. Each frame here adds ~1000/fps ms of tap→sound
    //   delay but suppresses that many frames of boundary flicker / false fires.
    //   Sweep it against LatencyProbe's HUD to find the balanced setting; raising
    //   `targetFrameRate` buys the latency back without loosening this.
    private let keyConfirmFramesFast = 2           // confirm window for a fast, deliberate arrival
    private let fastTapSpeed: Double = 0.25        // arrival speed (normalized units/s) above which a press counts as deliberate — a boundary flicker barely moves, a real tap sweeps in
    private let historySpan: TimeInterval = 0.18
    private let fingerTimeout: TimeInterval = 0.45  // hold a finger's identity through detection dropouts; retriggers after longer gaps are handled by `dropoutReleased`, so this can stay short enough that a vanished finger's note doesn't ring long
    private let liftReleaseSpeed: Double = 0.35    // tip speed (normalized units/s) above which a pressed finger counts as lifting — a holding finger is stationary
    private let liftMinHold: TimeInterval = 0.15   // ignore lift-speed for this long after note-on (the approach's own tail would otherwise damp the note it just played)
    private let repressInterval: TimeInterval = 0.09      // min gap between note-ons of the same key (anti-jitter only — a deliberate lift-and-retap is always legitimate)
    private let repressIntervalSustained: TimeInterval = 0.12  // sustained keys: same anti-jitter idea, slightly wider for held notes
    /// Keys released because tracking LOST the finger (prune / all-hands gone) —
    /// the finger probably never lifted, so the same key re-firing right after
    /// re-detection is a phantom retrigger, not a new tap. Deliberate move-offs
    /// are never marked here, which is what keeps fast repeated tapping free.
    private var dropoutReleased: [Int: TimeInterval] = [:]
    private let dropoutRepressGuard: TimeInterval = 0.4
    private let tipConfidence: Float = 0.25        // fingertip joint confidence floor — steep stand angles (phone tilted down at the sheet) foreshorten the hand and depress confidence; PressLog DETECT lines showed tips flickering below the old 0.4 floor

    /// Last camera-triggered note-on per key (video-queue-only) — caps how fast a
    /// flickering boundary can hammer the synth with retriggers.
    private var lastCameraPress: [Int: TimeInterval] = [:]

    // MARK: - Lifecycle

    func start() {
        checkAuthorization()
    }

    func stop() {
        session.stopRunning()
        FrameRecorder.shared.finish()   // finalize the diagnostic capture file
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

    /// The device zoom factor that shows the familiar 1× wide field of view.
    /// On a dual-wide virtual camera the ultra-wide lens sits *below* this
    /// (device factor 1.0 ≈ "0.5×"), giving auto-frame extra reach outward.
    private var defaultZoom: CGFloat = 1.0

    private var maxDeviceZoom: CGFloat {
        guard let device = captureDevice else { return 6 }
        return min(defaultZoom * 6.0, device.maxAvailableVideoZoomFactor)
    }

    /// Sets zoom in *display* units (1× = the familiar wide view; below 1× uses
    /// the ultra-wide lens where available). Used by pinch.
    func setZoom(_ displayFactor: CGFloat) {
        setDeviceZoom(displayFactor * defaultZoom)
    }

    private func setDeviceZoom(_ factor: CGFloat) {
        guard let device = captureDevice else { return }
        let clamped = max(device.minAvailableVideoZoomFactor, min(factor, maxDeviceZoom))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            let display = clamped / defaultZoom
            DispatchQueue.main.async { self.zoomFactor = display }
        } catch {
            print("zoom error: \(error)")
        }
    }

    /// Smoothly ramps to a device zoom factor (auto-frame's movements).
    private func rampDeviceZoom(to factor: CGFloat, rate: Float = 1.5) {
        guard let device = captureDevice else { return }
        let clamped = max(device.minAvailableVideoZoomFactor, min(factor, maxDeviceZoom))
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: clamped, withRate: rate)
            device.unlockForConfiguration()
            let display = clamped / defaultZoom
            DispatchQueue.main.async { self.zoomFactor = display }
        } catch {
            print("zoom ramp error: \(error)")
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
    /// Balance knob: bump to 120 to halve per-frame time (so `keyConfirmFrames`
    /// costs less latency) — but high-fps formats drop resolution, which starves
    /// the big-span per-key detail. Compare 60 vs 120 on LatencyProbe's HUD:
    /// watch achieved `fps` (does Vision keep up?) and the `captureLabel` resolution.
    private let targetFrameRate = 60.0

    /// Largest ≤1080p format that supports `targetFrameRate`. Resolution matters:
    /// the corner QR codes decode by pixels-per-module, and 1080p buys ~1.5× more
    /// than 720p — the difference between registering at play distance or not.
    private func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestPixels = 0
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.height >= 720, dims.height <= 1080 else { continue }
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= targetFrameRate })
            else { continue }
            let pixels = Int(dims.width) * Int(dims.height)
            if pixels > bestPixels { bestPixels = pixels; best = format }
        }
        return best
    }

    private func setupSession() {
        session.beginConfiguration()

        // Input — prefer the dual-wide virtual camera (wide + ultra-wide) so
        // auto-frame can zoom out beyond 1× to find the QR corners by itself;
        // fall back to the plain wide camera (Catalyst, older devices).
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInDualWideCamera,
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
        // On a virtual device the wide lens starts at the first switch-over
        // factor; device factor 1.0 is the ultra-wide's widest view.
        defaultZoom = device.virtualDeviceSwitchOverVideoZoomFactors.first
            .map { CGFloat(truncating: $0) } ?? 1.0
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
            LatencyProbe.shared.captureLabel = "\(dims.width)x\(dims.height)@\(Int(targetFrameRate))"
        } else {
            session.sessionPreset = .hd1280x720
            print("📷 capture format: 1280x720 @ default fps (no 60fps format)")
            LatencyProbe.shared.captureLabel = "1280x720@~30 (no \(Int(targetFrameRate))fps fmt)"
        }
        LatencyProbe.shared.targetFps = Int(targetFrameRate)
        LatencyProbe.shared.keyConfirmFrames = keyConfirmFrames

        // Keep the tabletop sheet sharp: continuous AF biased to near range.
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            #if !targetEnvironment(macCatalyst)
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            #endif
            device.unlockForConfiguration()
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
            guard let self else { return }
            self.session.startRunning()
            // Start at the familiar 1× wide view (not the ultra-wide extreme).
            self.setDeviceZoom(self.defaultZoom)
            DispatchQueue.main.async { self.isRunning = true }
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
        autoFramePaused = false
        autoFrameHint = nil
        setDeviceZoom(defaultZoom)   // fresh scan starts from the familiar 1× view
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.autoFrameActive = true
            self.lastHint = nil
            self.liveCalibration = KeyboardCalibration()
            self.isCalibratedOnVideoQueue = false
            self.scanCorners = []
            self.alignedSince = nil
            self.fingers.removeAll()
            self.handTracks.removeAll()
            for id in self.pressedKeyIDs {
                if let key = PaperPianoKey.byID(id, variant: self.currentVariantVQ) {
                    PianoAudioEngine.shared.stopNote(key: key)
                }
            }
            self.pressedKeyIDs.removeAll()
            DispatchQueue.main.async { self.activeNotes.removeAll() }
        }
    }

    func confirmAutoCalibration() {
        setCalibrationCorners(detectedCorners)
        if PressLog.enabled {
            PressLog.shared.log("CALIBRATE variant=\(calibration.variant) corners=["
                + detectedCorners.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: ",") + "]")
        }
        calibrationState = .calibrated
        foundMarkers = [:]
        detectedCorners = []
        autoFrameHint = nil
        videoQueue.async { [weak self] in self?.lastHint = nil }
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
            PianoAudioEngine.shared.playNote(key: key, velocity: velocity,
                                             channel: self.activeVariant.midiChannel)

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

        if LatencyProbe.enabled {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let host = LatencyProbe.hostNow()
            currentFramePresentationTime = pts.isFinite ? pts : host
            LatencyProbe.shared.recordFrame(presentationTime: currentFramePresentationTime, hostNow: host)
        }

        // Diagnostic video: record exactly what the detector sees during play,
        // time-anchored to the press log (see FrameRecorder).
        if FrameRecorder.enabled, isCalibratedOnVideoQueue {
            FrameRecorder.shared.append(sampleBuffer)
        }

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
            // Capture dropout transitions: we had fingers, now Vision sees no hand.
            if PressLog.enabled, !fingers.isEmpty {
                PressLog.shared.log("DROPOUT hadFingers=\(fingers.count)")
            }
            handleNoFingers()
            return
        }

        // Detection snapshot ~4×/s: hand count + every tip's confidence, so the
        // flicker (tips dipping below the confidence floor) is visible in data.
        if PressLog.enabled, frameIndex % 15 == 0 {
            let short = ["T", "I", "M", "R", "L"]   // thumb…little, same order as tipJoints
            var parts: [String] = []
            for (h, obs) in observations.enumerated() {
                for (j, joint) in Self.tipJoints.enumerated() {
                    if let p = try? obs.recognizedPoint(joint) {
                        parts.append(String(format: "h%d%@=%.2f", h, short[j], p.confidence))
                    }
                }
            }
            PressLog.shared.log("DETECT hands=\(observations.count) " + parts.joined(separator: " "))
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
                      point.confidence > tipConfidence else { continue }
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
            if let keyID = finger.pressedKeyID {
                if PressLog.enabled {
                    PressLog.shared.log(String(format: "PRUNE id=%d key=%d gap=%.2fs",
                                               finger.id, keyID, now - finger.lastSeen))
                }
                dropoutReleased[keyID] = now   // released by tracking loss, not by a lift
                releaseKey(keyID)
            }
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
        let now = Date().timeIntervalSinceReferenceDate
        for finger in fingers.values where finger.pressedKeyID != nil {
            dropoutReleased[finger.pressedKeyID!] = now   // lost, not lifted
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
            // Stamp when this finger first landed on the candidate key, for the
            // honest tap→sound number (this span is what the debounce spends).
            finger.candidateContactTime = currentFramePresentationTime
        }
        // Lift release (sustained keys): the camera can't see press depth, and a
        // straight-up lift slides the tip's projection ALONG the long key zone
        // rather than off it — "still inside the zone" doesn't mean "still
        // holding". A holding finger is stationary; a fast-moving tip is leaving.
        // Damp immediately (like a piano damper) and latch: the key can't sound
        // again until the finger moves off it or visibly settles onto it anew.
        let speed = arrivalSpeed(of: finger)
        if liveCalibration.variant.interactionModel == .sustained {
            if let pressed = finger.pressedKeyID, finger.awaitingDepartureFrom == nil,
               speed > liftReleaseSpeed,
               finger.lastSeen - finger.pressStartTime > liftMinHold {
                releaseKey(pressed)
                finger.pressedKeyID = nil
                finger.awaitingDepartureFrom = pressed
                finger.departureSettleCount = 0
                if PressLog.enabled {
                    PressLog.shared.log(String(format: "LIFT key=%d speed=%.2f", pressed, speed))
                }
            }
            if let waiting = finger.awaitingDepartureFrom {
                if finger.candidateKeyID != waiting {
                    finger.awaitingDepartureFrom = nil       // genuinely departed the key
                } else if speed < liftReleaseSpeed {
                    finger.departureSettleCount += 1         // hover ended: settling back on = a new press
                    if finger.departureSettleCount >= keyConfirmFramesFast {
                        finger.awaitingDepartureFrom = nil
                    }
                } else {
                    finger.departureSettleCount = 0
                }
            }
        }

        // Adaptive confirm: a fast, deliberate arrival fires a frame sooner than a
        // slow drift across a key boundary — responsiveness where intent is clear,
        // debounce where it's ambiguous.
        let required = speed > fastTapSpeed ? keyConfirmFramesFast : keyConfirmFrames
        guard finger.candidateCount >= required else { return }
        // Still latched on a lift-released key: no sound until it departs/re-settles.
        if let waiting = finger.awaitingDepartureFrom, finger.candidateKeyID == waiting { return }

        // Edge trigger: only act when the confirmed key differs from what's sounding.
        guard finger.candidateKeyID != finger.pressedKeyID else { return }
        if let old = finger.pressedKeyID { releaseKey(old) }
        finger.pressedKeyID = nil
        if let key, key.id == finger.candidateKeyID {
            if LatencyProbe.enabled {
                LatencyProbe.shared.recordNote(confirmSeconds: LatencyProbe.hostNow() - finger.candidateContactTime)
            }
            let velocity = arrivalVelocity(of: finger)
            if PressLog.enabled {
                let kb = liveCalibration.normalizedPoint(from: pt, previewSize: CGSize(width: 1, height: 1)) ?? .zero
                PressLog.shared.log(String(format:
                    "PRESS fp=(%.3f,%.3f) kb=(%.3f,%.3f) -> %@%d id=%d frameMidX=%.3f ch=%d var=%@ vel=%.2f req=%d",
                    pt.x, pt.y, kb.x, kb.y, String(describing: key.note), key.octave, key.id,
                    key.normalizedFrame.midX, Int(liveCalibration.variant.midiChannel),
                    String(describing: liveCalibration.variant), velocity, required))
            }
            switch liveCalibration.variant.interactionModel {
            case .sustained: pressKey(key, velocity: velocity)
            case .struckOnce: strikeKey(key, velocity: velocity)
            }
            finger.pressedKeyID = key.id
            finger.pressStartTime = finger.lastSeen
        }
    }

    /// Raw approach speed over the finger's recent history (normalized units/s).
    /// Feeds both the adaptive confirm window and the strike velocity.
    private func arrivalSpeed(of finger: TrackedFinger) -> Double {
        guard let first = finger.history.first, let last = finger.history.last,
              last.t - first.t > 0.01 else { return 0 }
        return distance(last.pt, first.pt) / (last.t - first.t)
    }

    /// Expressive dynamics: a fast strike lands loud, a gentle placement soft.
    private func arrivalVelocity(of finger: TrackedFinger) -> Float {
        let speed = arrivalSpeed(of: finger)
        guard speed > 0 else { return 0.7 }
        return Float(min(1.0, 0.45 + speed * 1.2))
    }

    private func distance(_ p: CGPoint, _ q: CGPoint) -> Double {
        Double(hypot(p.x - q.x, p.y - q.y))
    }

    /// Note-on for a sustained press (held until `releaseKey`). Audio fires
    /// directly from the video queue — no main-thread hop in the sound path.
    private func pressKey(_ key: PaperPianoKey, velocity: Float) {
        guard !pressedKeyIDs.contains(key.id) else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if let t = dropoutReleased[key.id], now - t < dropoutRepressGuard { return }
        if let last = lastCameraPress[key.id], now - last < repressIntervalSustained { return }
        dropoutReleased.removeValue(forKey: key.id)
        lastCameraPress[key.id] = now
        pressedKeyIDs.insert(key.id)
        PianoAudioEngine.shared.holdNote(key: key, velocity: velocity,
                                         channel: liveCalibration.variant.midiChannel)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeNotes.removeAll { $0.key.id == key.id }
            self.activeNotes.append(ActiveNote(key: key, startTime: Date(), velocity: velocity))
            #if !targetEnvironment(macCatalyst)
            self.noteHaptic.impactOccurred()
            #endif
        }
    }

    /// Note-on for a struck zone (drum pad, mallet bar, plucked string): fires
    /// once on arrival and is expected to decay on its own, unlike a sustained
    /// piano/organ press. Deliberately does NOT add to `pressedKeyIDs` — that's
    /// what makes the `releaseKey` call in `evaluatePress` (fired when the
    /// finger later moves off or lifts) a safe no-op here instead of stopping
    /// a note that was never being held in the first place.
    private func strikeKey(_ key: PaperPianoKey, velocity: Float) {
        let now = Date().timeIntervalSinceReferenceDate
        if let t = dropoutReleased[key.id], now - t < dropoutRepressGuard { return }
        if let last = lastCameraPress[key.id], now - last < repressInterval { return }
        dropoutReleased.removeValue(forKey: key.id)
        lastCameraPress[key.id] = now
        PianoAudioEngine.shared.playPercussiveNote(key: key, velocity: velocity,
                                                    channel: liveCalibration.variant.midiChannel)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeNotes.removeAll { $0.key.id == key.id }
            self.activeNotes.append(ActiveNote(key: key, startTime: Date(), velocity: velocity))
            #if !targetEnvironment(macCatalyst)
            self.noteHaptic.impactOccurred()
            #endif
            // No sustain to track — clear the UI highlight after a quick flash
            // rather than waiting for a release that will never come.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.activeNotes.removeAll { $0.key.id == key.id }
            }
        }
    }

    /// Note-off for a previously pressed key.
    private func releaseKey(_ keyID: Int) {
        guard pressedKeyIDs.remove(keyID) != nil else { return }
        if let key = PaperPianoKey.byID(keyID, variant: currentVariantVQ) {
            PianoAudioEngine.shared.stopNote(key: key, channel: currentVariantVQ.midiChannel)
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

    /// Mid-play sheet-swap debounce (video-queue-owned): a different sheet must
    /// win `sheetSwapConfirmDetections` consecutive QR passes before it replaces
    /// the locked one. ~5 Hz once calibrated → 8 ≈ 1.6 s of consistent intent.
    private var pendingSheetSwap: (variant: KeyboardVariant, count: Int)?
    private let sheetSwapConfirmDetections = 8

    /// All 4 corners must hold steady this long before the state advances to
    /// .aligned (the "short delay confirming recognition").
    private let alignStability: TimeInterval = 0.5
    /// Missed detections shorter than this don't bounce the UI back to scanning —
    /// the single-frame flicker that made registration feel jittery.
    private let markerGrace: TimeInterval = 0.4

    /// Locates the keyboard from the four corner QR codes. Each QR encodes its
    /// corner and sheet variant ("TAPNOTE:3:TL" = 3-octave, "TAPNOTE:2:TL" =
    /// 2-octave, …), so the paper identifies itself: detection is unambiguous,
    /// robust to lighting/angle, and the app switches key layouts automatically.
    /// Pre-token legacy prints ("TAPNOTE:TL") are deliberately not recognized.
    private func detectQRCorners(_ results: [VNBarcodeObservation], now: TimeInterval) {
        var byVariant: [KeyboardVariant: [String: CGPoint]] = [:]
        var spanSum: CGFloat = 0
        var spanCount = 0
        for obs in results {
            guard let payload = obs.payloadStringValue,
                  payload.hasPrefix("TAPNOTE:") else { continue }
            let rawSuffix = String(payload.dropFirst("TAPNOTE:".count))
            // Legacy bare-form markers (no sheet token) parse as nil and are
            // ignored entirely — stray pre-token prints on the desk must never
            // enter the candidate set. See KeyboardVariant.parseToken.
            guard let (variant, suffix) = KeyboardVariant.parseToken(from: rawSuffix) else { continue }
            // boundingBox is normalized with a bottom-left origin — flip Y to match
            // the fingertip coordinate space.
            let center = CGPoint(x: obs.boundingBox.midX, y: 1 - obs.boundingBox.midY)
            byVariant[variant, default: [:]][suffix] = center
            spanSum += max(obs.boundingBox.width, obs.boundingBox.height)
            spanCount += 1
        }
        let avgMarkerSpan = spanCount > 0 ? spanSum / CGFloat(spanCount) : 0

        // Multiple sheets can be in frame at once (old prints on the same desk —
        // observed in the field: a legacy sheet hijacked a live session). Prefer a
        // complete 4-corner set, and among complete sets the LARGEST quad: the
        // sheet the user actually framed dominates the view, stray ones are small.
        func quadArea(_ m: [String: CGPoint]) -> CGFloat {
            guard let tl = m["TL"], let tr = m["TR"], let bl = m["BL"], let br = m["BR"]
            else { return 0 }
            let p = [tl, tr, br, bl]   // shoelace over the perimeter order
            var a: CGFloat = 0
            for i in 0..<4 { a += p[i].x * p[(i + 1) % 4].y - p[(i + 1) % 4].x * p[i].y }
            return abs(a) / 2
        }
        func score(_ m: [String: CGPoint]) -> CGFloat {
            CGFloat(m.count) * 10 + (m.count == 4 ? 100 + quadArea(m) * 50 : 0)
        }
        let best = byVariant.max { score($0.value) < score($1.value) }
        let found = best?.value ?? [:]

        if let variant = best?.key, found.count == 4 {
            if !isCalibratedOnVideoQueue {
                // Registering: follow the best candidate freely.
                if variant != currentVariantVQ { setVariantOnVideoQueue(variant) }
                pendingSheetSwap = nil
            } else if variant != currentVariantVQ {
                // Mid-play sheet swap must be STICKY: a single frame of another
                // sheet's QRs (stray print, misread) must never hijack a locked
                // session. Require the other sheet to win consistently for
                // ~1.2s (QR runs ~10 Hz once calibrated) before switching.
                if pendingSheetSwap?.variant == variant {
                    pendingSheetSwap = (variant, pendingSheetSwap!.count + 1)
                } else {
                    pendingSheetSwap = (variant, 1)
                }
                if pendingSheetSwap!.count >= sheetSwapConfirmDetections,
                   let tl = found["TL"], let tr = found["TR"],
                   let bl = found["BL"], let br = found["BR"] {
                    setVariantOnVideoQueue(variant)
                    let c = [tl, tr, bl, br]
                    liveCalibration.setCorners(c)
                    if PressLog.enabled {
                        PressLog.shared.log("SWAP variant=\(variant) corners=["
                            + c.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: ",") + "]")
                    }
                    DispatchQueue.main.async { [weak self] in self?.calibration.setCorners(c) }
                    // Audible confirmation — the player is watching the paper,
                    // not the screen; an instrument change must never be silent.
                    PianoAudioEngine.shared.playCalibrationCue()
                    pendingSheetSwap = nil
                }
            } else {
                pendingSheetSwap = nil   // steady on the current sheet
            }
        }

        // Per-marker feedback while registering: highlight each recognized corner,
        // and let auto-frame adjust the camera to hunt for the missing ones.
        if !isCalibratedOnVideoQueue {
            DispatchQueue.main.async { [weak self] in self?.foundMarkers = found }
            updateAutoFrame(found: found, avgMarkerSpan: avgMarkerSpan, now: now)
        }

        if let tl = found["TL"], let tr = found["TR"],
           let bl = found["BL"], let br = found["BR"] {
            markersFound([tl, tr, bl, br], now: now)
        } else {
            markersMissing(now: now)
        }
    }

    /// Video-queue-side variant switch, mirrored to the published copies.
    private func setVariantOnVideoQueue(_ variant: KeyboardVariant) {
        currentVariantVQ = variant
        liveCalibration.variant = variant
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.calibration.variant = variant
            self.activeVariant = variant
        }
    }

    /// Manual variant selection (manual calibration has no QR payloads to read).
    func setKeyboardVariant(_ variant: KeyboardVariant) {
        calibration.variant = variant
        activeVariant = variant
        videoQueue.async { [weak self] in
            self?.currentVariantVQ = variant
            self?.liveCalibration.variant = variant
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

    // MARK: - Auto-Frame (registration only)

    // The camera can't aim itself, but it can hunt with zoom: widen (down to the
    // ultra-wide lens) until all 4 corner QRs appear, then tighten on the found
    // keyboard. All state is video-queue-owned, like the rest of detection.
    private var autoFrameActive = true
    private var lastAutoFrameAction: TimeInterval = 0
    private var lastHint: AutoFrameHint?
    private let autoFrameInterval: TimeInterval = 0.5
    private static let markerNames = ["TL", "TR", "BL", "BR"]

    /// Pauses auto-framing (manual pinch or manual calibration takes over).
    func pauseAutoFrame() {
        autoFramePaused = true
        videoQueue.async { [weak self] in
            self?.autoFrameActive = false
            self?.publishHint(nil)
        }
    }

    func resumeAutoFrame() {
        autoFramePaused = false
        videoQueue.async { [weak self] in self?.autoFrameActive = true }
    }

    /// Decoded markers smaller than this (normalized frame fraction) suggest the
    /// missing corners are in frame but too small to decode — zoom IN, not out.
    private let smallMarkerSpan: CGFloat = 0.045

    private func updateAutoFrame(found: [String: CGPoint], avgMarkerSpan: CGFloat, now: TimeInterval) {
        guard autoFrameActive else { return }
        guard now - lastAutoFrameAction >= autoFrameInterval else { return }
        guard let device = captureDevice else { return }
        let current = device.videoZoomFactor
        let minZoom = device.minAvailableVideoZoomFactor

        // Partial detection with tiny-but-decoding markers: the sheet is small in
        // frame, so the missing corners are likely present yet unreadable. Widening
        // makes them smaller still — tighten instead (while the found cluster
        // comfortably fits).
        if (1...3).contains(found.count), avgMarkerSpan > 0, avgMarkerSpan < smallMarkerSpan {
            let xs = found.values.map(\.x), ys = found.values.map(\.y)
            let clusterSpan = max((xs.max()! - xs.min()!), (ys.max()! - ys.min()!))
            if clusterSpan < 0.5 {
                rampDeviceZoom(to: current * 1.15)
                lastAutoFrameAction = now
                publishHint(.zoomingIn)
                return
            }
        }

        switch found.count {
        case 4:
            // Tighten on the keyboard — but keep generous margin: the margin is
            // HAND room, not slack. At a downward stand angle the palm/wrist of a
            // hand playing the near edge extends past the sheet toward the frame
            // edge, and Vision's hand-pose model fails on a cropped hand (press-log
            // data: near-end keys went dead while far-end keys tracked). So cap the
            // sheet at ~65% of frame instead of the old 90%.
            let xs = found.values.map(\.x), ys = found.values.map(\.y)
            let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
            if span < 0.45 {
                rampDeviceZoom(to: current * min(1.2, 0.6 / max(span, 0.05)))
                lastAutoFrameAction = now
                publishHint(.zoomingIn)
            } else if span > 0.65 {
                rampDeviceZoom(to: current * 0.9)
                lastAutoFrameAction = now
                publishHint(.zoomingOut)
            } else {
                publishHint(nil)   // framed well — hold
            }

        case 3:
            let missing = Self.markerNames.filter { found[$0] == nil }
            // The three known corners determine the fourth (parallelogram).
            if let estimate = estimateMissingCorner(missing[0], found: found),
               (0...1).contains(estimate.x), (0...1).contains(estimate.y) {
                // Predicted spot is IN frame — zooming won't help (occlusion or
                // glare); show the ghost target instead.
                publishHint(.aimToward(corners: missing, estimate: estimate))
            } else {
                publishHint(.aimToward(corners: missing,
                                       estimate: nil))
                zoomOutStep(current: current, minZoom: minZoom, now: now)
            }

        case 1, 2:
            let missing = Self.markerNames.filter { found[$0] == nil }
            if current > minZoom + 0.01 {
                publishHint(.zoomingOut)
                zoomOutStep(current: current, minZoom: minZoom, now: now)
            } else {
                publishHint(.aimToward(corners: missing, estimate: nil))
            }

        default:  // 0 markers
            if current > minZoom + 0.01 {
                publishHint(.zoomingOut)
                zoomOutStep(current: current, minZoom: minZoom, now: now)
            } else {
                publishHint(.searchWider)
            }
        }
    }

    /// One zoom-out step, pausing at the 1× wide view before committing to the
    /// ultra-wide lens below it.
    private func zoomOutStep(current: CGFloat, minZoom: CGFloat, now: TimeInterval) {
        let target: CGFloat
        if current > defaultZoom + 0.01 {
            target = max(defaultZoom, current * 0.85)
        } else {
            target = max(minZoom, current * 0.85)
        }
        guard target < current - 0.005 else { return }
        rampDeviceZoom(to: target)
        lastAutoFrameAction = now
    }

    /// Where the missing corner must be, from the three found ones:
    /// opposite corners of a parallelogram sum equally (TL + BR = TR + BL).
    private func estimateMissingCorner(_ missing: String, found: [String: CGPoint]) -> CGPoint? {
        func p(_ n: String) -> CGPoint? { found[n] }
        switch missing {
        case "TL": if let a = p("TR"), let b = p("BL"), let c = p("BR") {
            return CGPoint(x: a.x + b.x - c.x, y: a.y + b.y - c.y) }
        case "TR": if let a = p("TL"), let b = p("BR"), let c = p("BL") {
            return CGPoint(x: a.x + b.x - c.x, y: a.y + b.y - c.y) }
        case "BL": if let a = p("TL"), let b = p("BR"), let c = p("TR") {
            return CGPoint(x: a.x + b.x - c.x, y: a.y + b.y - c.y) }
        case "BR": if let a = p("TR"), let b = p("BL"), let c = p("TL") {
            return CGPoint(x: a.x + b.x - c.x, y: a.y + b.y - c.y) }
        default: break
        }
        return nil
    }

    private func publishHint(_ hint: AutoFrameHint?) {
        guard hint != lastHint else { return }
        lastHint = hint
        DispatchQueue.main.async { [weak self] in self?.autoFrameHint = hint }
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
