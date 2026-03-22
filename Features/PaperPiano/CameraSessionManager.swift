import Foundation
import AVFoundation
import Vision
import Combine
import CoreImage
import SwiftUI

// MARK: - Camera Session Manager

class CameraSessionManager: NSObject, ObservableObject {

    // MARK: Published

    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var isRunning = false
    @Published var isAuthorized = false
    @Published var latestFingerResult: FingerDetectionResult? = nil
    @Published var calibration = KeyboardCalibration()
    @Published var activeNotes: [ActiveNote] = []
    @Published var detectedCorners: [CGPoint] = []   // orange corner markers found by Vision
    @Published var calibrationState: CalibrationState = .idle

    enum CalibrationState {
        case idle
        case scanning           // looking for corner markers
        case aligned            // found all 4 corners, ready to confirm
        case calibrated         // user confirmed, ready to play
    }

    // MARK: Private

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.muselearn.camera", qos: .userInteractive)

    // Vision requests
    private var handPoseRequest = VNDetectHumanHandPoseRequest()
    private var rectangleRequest = VNDetectRectanglesRequest()

    // Debounce rapid note triggers
    private var lastNoteTime: [Int: Date] = [:]
    private let noteDebounce: TimeInterval = 0.15

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
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    if granted { self?.setupSession() }
                }
            }
        default:
            isAuthorized = false
        }
    }

    // MARK: - Session Setup

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

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
        if session.canAddInput(input) { session.addInput(input) }

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
        }

        // Configure Vision requests
        handPoseRequest.maximumHandCount = 2
        handPoseRequest.revision = VNDetectHumanHandPoseRequestRevision1

        rectangleRequest.minimumAspectRatio = 0.1
        rectangleRequest.maximumAspectRatio = 1.0
        rectangleRequest.minimumSize = 0.3
        rectangleRequest.maximumObservations = 1

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async { self?.isRunning = true }
        }
    }

    // MARK: - Manual Calibration (tap fallback)

    func addCalibrationCorner(_ point: CGPoint) {
        guard calibration.corners.count < 4 else { return }
        calibration.corners.append(point)
        if calibration.corners.count == 4 {
            calibrationState = .calibrated
        }
    }

    func resetCalibration() {
        calibration = KeyboardCalibration()
        calibrationState = .idle
        detectedCorners = []
    }

    func confirmAutoCalibration() {
        calibration.corners = detectedCorners
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

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up, options: [:])

        // Run hand pose detection
        try? handler.perform([handPoseRequest])
        processHandPose()

        // Auto-calibration: detect the orange rectangle border
        if calibrationState == .idle || calibrationState == .scanning {
            try? handler.perform([rectangleRequest])
            processRectangleDetection()
        }
    }

    private func processHandPose() {
        guard let observations = handPoseRequest.results, !observations.isEmpty else { return }
        guard calibration.isCalibrated else { return }

        var fingerTips: [CGPoint] = []

        for observation in observations {
            // Get all fingertip landmarks
            let tips: [VNHumanHandPoseObservation.JointName] = [
                .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip
            ]
            for tipName in tips {
                guard let point = try? observation.recognizedPoint(tipName),
                      point.confidence > 0.5 else { continue }
                // VNPoint has y-flipped (0=bottom), convert to standard UIKit/normalized
                let pt = CGPoint(x: point.location.x, y: 1 - point.location.y)
                fingerTips.append(pt)
            }
        }

        if !fingerTips.isEmpty {
            let result = FingerDetectionResult(fingerTips: fingerTips, timestamp: Date().timeIntervalSinceReferenceDate)
            DispatchQueue.main.async { [weak self] in
                self?.latestFingerResult = result
            }

            // Check which keys are being touched
            for tip in fingerTips {
                // Convert normalized camera point → preview size doesn't matter here
                // We use calibration to map directly
                if let key = calibration.key(at: tip, previewSize: CGSize(width: 1, height: 1)) {
                    triggerKey(key, velocity: 0.75)
                }
            }
        }
    }

    private func processRectangleDetection() {
        guard let observations = rectangleRequest.results, !observations.isEmpty else { return }
        guard let rect = observations.first else { return }

        // Vision returns normalized coords (0…1), y-flipped
        let tl = CGPoint(x: rect.topLeft.x,     y: 1 - rect.topLeft.y)
        let tr = CGPoint(x: rect.topRight.x,    y: 1 - rect.topRight.y)
        let bl = CGPoint(x: rect.bottomLeft.x,  y: 1 - rect.bottomLeft.y)
        let br = CGPoint(x: rect.bottomRight.x, y: 1 - rect.bottomRight.y)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detectedCorners = [tl, tr, bl, br]
            if self.calibrationState == .idle || self.calibrationState == .scanning {
                self.calibrationState = .aligned
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
