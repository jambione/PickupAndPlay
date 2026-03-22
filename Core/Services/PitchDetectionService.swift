import Foundation
import AVFoundation
import Accelerate
import Combine

class PitchDetectionService: ObservableObject {

    // MARK: - Published

    @Published var currentResult: PitchDetectionResult? = nil
    @Published var isListening: Bool = false
    @Published var permissionGranted: Bool = false

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private let bufferSize: AVAudioFrameCount = 4096
    private var expectedNote: MusicalNote? = nil

    // MARK: - Init

    init() {
        checkPermission()
    }

    // MARK: - Permission

    func checkPermission() {
        #if os(iOS)
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            permissionGranted = true
        case .denied:
            permissionGranted = false
        case .undetermined:
            requestPermission()
        @unknown default:
            break
        }
        #elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionGranted = true
        case .notDetermined:
            requestPermission()
        default:
            permissionGranted = false
        }
        #endif
    }

    func requestPermission() {
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.permissionGranted = granted
            }
        }
        #elseif os(macOS)
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.permissionGranted = granted
            }
        }
        #endif
    }

    // MARK: - Start / Stop

    func startListening(expecting note: MusicalNote? = nil) {
        guard permissionGranted else {
            requestPermission()
            return
        }
        expectedNote = note
        setupAudioEngine()
        isListening = true
    }

    func stopListening() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isListening = false
        currentResult = nil
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        audioEngine?.stop()
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer, sampleRate: format.sampleRate)
        }

        do {
            try engine.start()
        } catch {
            print("Audio engine failed to start: \(error)")
            isListening = false
        }
    }

    // MARK: - Pitch Detection (YIN-like autocorrelation)

    private func processBuffer(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        var samples = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress?.update(from: channelData, count: frameCount)
        }

        guard let frequency = autocorrelationPitchDetection(samples: samples, sampleRate: sampleRate) else {
            return
        }

        let (note, octave) = frequencyToNote(frequency: frequency)
        let expected = expectedNote
        let isAccurate: Bool
        if let exp = expected, let detectedNote = note {
            isAccurate = detectedNote == exp.pitch && octave == exp.octave
        } else {
            isAccurate = false
        }

        let result = PitchDetectionResult(
            detectedFrequency: frequency,
            detectedNote: note,
            detectedOctave: octave,
            confidence: 0.85,
            isAccurate: isAccurate
        )

        DispatchQueue.main.async { [weak self] in
            self?.currentResult = result
        }
    }

    private func autocorrelationPitchDetection(samples: [Float], sampleRate: Double) -> Double? {
        let n = samples.count
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        guard rms > 0.01 else { return nil } // silence threshold

        var acf = [Float](repeating: 0, count: n)
        for lag in 0..<n {
            var sum: Float = 0
            for i in 0..<(n - lag) {
                sum += samples[i] * samples[i + lag]
            }
            acf[lag] = sum
        }

        // Find the first peak after the initial drop
        let minLag = Int(sampleRate / 1200) // ~C6 max frequency
        let maxLag = Int(sampleRate / 50)   // ~50Hz min frequency

        var bestLag = minLag
        var bestValue: Float = 0
        var i = minLag
        while i < min(maxLag, n - 1) {
            if acf[i] > acf[i-1] && acf[i] > acf[i+1] && acf[i] > bestValue {
                bestValue = acf[i]
                bestLag = i
            }
            i += 1
        }

        guard bestLag > 0 && bestValue > 0 else { return nil }
        return sampleRate / Double(bestLag)
    }

    private func frequencyToNote(frequency: Double) -> (NotePitch?, Int?) {
        guard frequency > 0 else { return (nil, nil) }
        // A4 = 440 Hz
        let semitones = 12 * log2(frequency / 440.0)
        let roundedSemitones = Int(round(semitones))

        // Map semitone offset to note + octave
        let noteIndex = ((roundedSemitones % 12) + 12 + 9) % 12  // offset from C
        let octave = 4 + (roundedSemitones + 9) / 12

        let pitches: [NotePitch] = [.C, .CSharp, .D, .DSharp, .E, .F, .FSharp, .G, .GSharp, .A, .ASharp, .B]
        let pitch = pitches[noteIndex % 12]
        return (pitch, octave)
    }
}
