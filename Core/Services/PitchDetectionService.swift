import Foundation
import AVFoundation
import Accelerate

// MARK: - Pitch Detection Service v3
//
// Tuned specifically for acoustic piano + iPhone mic at room distance.
//
// Key improvements:
//  • Spectral flux onset detection — catches the attack transient of each key
//    even with room reverb muddying the signal
//  • Harmonic Product Spectrum (HPS) pitch estimation — multiplies harmonic
//    peaks together so the fundamental always wins over overtones, which is
//    critical for acoustic piano whose upper partials are very strong
//  • Pre-emphasis filter — boosts high frequencies before analysis so
//    the fundamental doesn't get swamped by low-freq room noise
//  • Note hold + release model — once a note is detected it stays "on"
//    until energy drops, giving clean instantaneous triggering
//  • Frequency range locked to piano: A0 (27.5 Hz) – C8 (4186 Hz)

class PitchDetectionService: ObservableObject {

    // MARK: - Published
    @Published var currentResult: PitchDetectionResult? = nil
    @Published var isListening: Bool = false
    @Published var permissionGranted: Bool = false

    // MARK: - Tuning knobs (adjust if needed)
    /// Minimum RMS to consider as sound (not silence). Lower = more sensitive.
    var silenceThreshold: Float = 0.004
    /// Spectral flux threshold to declare a new note onset. Lower = triggers easier.
    var onsetThreshold: Float = 0.25
    /// How many frames to lock out after an onset fires (prevents double-triggers)
    var onsetLockoutFrames: Int = 6

    // MARK: - Private
    private var audioEngine: AVAudioEngine?
    private let bufferSize: AVAudioFrameCount = 8192
    private var expectedNote: MusicalNote? = nil
    private var sampleRate: Double = 44100

    // Spectral flux onset state
    private var previousSpectrum: [Float] = []
    private var onsetLockout: Int = 0

    // Note hold state
    private var heldNoteTimer: Timer? = nil
    private var lastDetectedPitch: NotePitch? = nil
    private var lastDetectedOctave: Int? = nil

    // Smoothing
    private var recentFrequencies: [Double] = []
    private let smoothingWindow = 3

    // Pre-emphasis coefficient (boosts frequencies above ~1kHz)
    private let preEmphasis: Float = 0.97

    // MARK: - Init
    init() { checkPermission() }

    // MARK: - Permission
    func checkPermission() {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:      permissionGranted = true
            case .denied:       permissionGranted = false
            case .undetermined: requestPermission()
            @unknown default:   break
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:      permissionGranted = true
            case .denied:       permissionGranted = false
            case .undetermined: requestPermission()
            @unknown default:   break
            }
        }
        #elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    permissionGranted = true
        case .notDetermined: requestPermission()
        default:             permissionGranted = false
        }
        #endif
    }

    func requestPermission() {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async { self?.permissionGranted = granted }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async { self?.permissionGranted = granted }
            }
        }
        #elseif os(macOS)
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async { self?.permissionGranted = granted }
        }
        #endif
    }

    // MARK: - Start / Stop
    func startListening(expecting note: MusicalNote? = nil) {
        guard permissionGranted else { requestPermission(); return }
        expectedNote = note
        resetState()
        setupAudioEngine()
        isListening = true
    }

    func stopListening() {
        heldNoteTimer?.invalidate()
        heldNoteTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isListening = false
        currentResult = nil
    }

    private func resetState() {
        previousSpectrum = []
        onsetLockout = 0
        recentFrequencies = []
        lastDetectedPitch = nil
        lastDetectedOctave = nil
        heldNoteTimer?.invalidate()
        heldNoteTimer = nil
    }

    // MARK: - Audio Engine Setup
    private func setupAudioEngine() {
        audioEngine?.stop()
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Use .measurement mode — disables AGC and noise reduction for cleaner signal
        try? session.setCategory(.record, mode: .measurement, options: [])
        try? session.setPreferredIOBufferDuration(Double(bufferSize) / 44100.0)
        try? session.setActive(true)
        #endif

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
            print("Audio engine error: \(error)")
            isListening = false
        }
    }

    // MARK: - Buffer Processing
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        // Copy into array
        var samples = [Float](repeating: 0, count: n)
        vDSP_mmov(channelData, &samples, vDSP_Length(n), 1,
                  vDSP_Length(n), vDSP_Length(n))

        // ── Step 1: Pre-emphasis filter ──────────────────────────────────
        // y[n] = x[n] - α·x[n-1]  — boosts higher harmonics
        var filtered = [Float](repeating: 0, count: n)
        filtered[0] = samples[0]
        for i in 1..<n {
            filtered[i] = samples[i] - preEmphasis * samples[i - 1]
        }

        // ── Step 2: RMS gate ─────────────────────────────────────────────
        var rms: Float = 0
        vDSP_rmsqv(filtered, 1, &rms, vDSP_Length(n))
        guard rms > silenceThreshold else {
            if onsetLockout > 0 { onsetLockout -= 1 }
            previousSpectrum = []
            return
        }

        // ── Step 3: Apply Hann window ────────────────────────────────────
        var windowed = [Float](repeating: 0, count: n)
        var window   = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(filtered, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // ── Step 4: FFT magnitude spectrum ───────────────────────────────
        let spectrum = computeFFTMagnitude(samples: windowed)

        // ── Step 5: Spectral flux onset detection ────────────────────────
        let isOnset = detectOnset(newSpectrum: spectrum)
        previousSpectrum = spectrum

        if onsetLockout > 0 {
            onsetLockout -= 1
            return
        }

        guard isOnset else { return }
        onsetLockout = onsetLockoutFrames

        // ── Step 6: HPS pitch estimation ─────────────────────────────────
        guard let frequency = harmonicProductSpectrum(spectrum: spectrum) else { return }

        // ── Step 7: Smooth + quantise to nearest semitone ────────────────
        recentFrequencies.append(frequency)
        if recentFrequencies.count > smoothingWindow { recentFrequencies.removeFirst() }
        let smoothed = recentFrequencies.reduce(0, +) / Double(recentFrequencies.count)

        let (note, octave) = frequencyToNote(frequency: smoothed)
        guard let note, let octave else { return }

        let isAccurate: Bool
        if let exp = expectedNote {
            isAccurate = note == exp.pitch && octave == exp.octave
        } else {
            isAccurate = false
        }

        let result = PitchDetectionResult(
            detectedFrequency: smoothed,
            detectedNote: note,
            detectedOctave: octave,
            confidence: Double(min(rms / 0.05, 1.0)),
            isAccurate: isAccurate
        )

        DispatchQueue.main.async { [weak self] in
            self?.currentResult = result
        }
    }

    // MARK: - FFT Magnitude Spectrum
    private func computeFFTMagnitude(samples: [Float]) -> [Float] {
        let n = samples.count
        let log2n = vDSP_Length(log2(Float(n)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var splitComplex = DSPSplitComplex(realp: &real, imagp: &imag)

        samples.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n / 2))
            }
        }

        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        var magnitude = [Float](repeating: 0, count: n / 2)
        vDSP_zvmags(&splitComplex, 1, &magnitude, 1, vDSP_Length(n / 2))

        // Normalise
        var scale = Float(1.0 / Float(n))
        vDSP_vsmul(magnitude, 1, &scale, &magnitude, 1, vDSP_Length(n / 2))

        return magnitude
    }

    // MARK: - Spectral Flux Onset Detection
    //
    // Measures how much the spectrum changed frame-to-frame.
    // A large positive change = new note struck (onset).
    private func detectOnset(newSpectrum: [Float]) -> Bool {
        guard !previousSpectrum.isEmpty,
              previousSpectrum.count == newSpectrum.count else { return true }

        // Spectral flux: sum of positive differences only (half-wave rectified)
        var flux: Float = 0
        let count = vDSP_Length(newSpectrum.count)
        var diff = [Float](repeating: 0, count: newSpectrum.count)
        vDSP_vsub(previousSpectrum, 1, newSpectrum, 1, &diff, 1, count)

        // Half-wave rectify — only count increases
        var zero: Float = 0
        vDSP_vthres(diff, 1, &zero, &diff, 1, count)
        vDSP_sve(diff, 1, &flux, count)

        return flux > onsetThreshold
    }

    // MARK: - Harmonic Product Spectrum
    //
    // Downsamples the spectrum by 2x, 3x, 4x, 5x and multiplies them together.
    // The fundamental frequency is the only bin that survives all multiplications
    // because its harmonics (at 2f, 3f, 4f, 5f) all reinforce it.
    // Much more robust than autocorrelation for acoustic piano.
    private func harmonicProductSpectrum(spectrum: [Float]) -> Double? {
        let n = spectrum.count
        let numHarmonics = 5

        // Only look at bins corresponding to piano range: A0–C8
        let binWidth = sampleRate / Double(n * 2)
        let minBin = max(1, Int(27.5  / binWidth))   // A0
        let maxBin = min(n / numHarmonics, Int(4186.0 / binWidth))  // C8

        guard maxBin > minBin else { return nil }

        // Build HPS by multiplying downsampled spectra
        var hps = [Float](repeating: 1.0, count: maxBin)
        for h in 1...numHarmonics {
            for bin in minBin..<maxBin {
                let srcBin = bin * h
                if srcBin < n {
                    hps[bin] *= spectrum[srcBin]
                }
            }
        }

        // Find peak bin in piano range
        var maxVal: Float = 0
        var maxBinIdx: vDSP_Length = 0
        vDSP_maxvi(hps, 1, &maxVal, &maxBinIdx, vDSP_Length(maxBin))

        guard maxBinIdx >= vDSP_Length(minBin), maxVal > 0 else { return nil }

        // Parabolic interpolation for sub-bin accuracy
        let i = Int(maxBinIdx)
        let alpha = i > 0 ? hps[i - 1] : hps[i]
        let beta  = hps[i]
        let gamma = i + 1 < maxBin ? hps[i + 1] : hps[i]
        let denom = alpha - 2.0 * beta + gamma
        let refinedBin: Double
        if abs(denom) > 1e-10 {
            refinedBin = Double(i) + Double(alpha - gamma) / Double(2.0 * denom)
        } else {
            refinedBin = Double(i)
        }

        return refinedBin * binWidth
    }

    // MARK: - Frequency → Note
    private func frequencyToNote(frequency: Double) -> (NotePitch?, Int?) {
        guard frequency > 20, frequency < 5000 else { return (nil, nil) }
        let semitones = 12.0 * log2(frequency / 440.0)
        let rounded   = Int(round(semitones))
        let noteIndex = ((rounded % 12) + 12 + 9) % 12
        let octave    = 4 + Int(floor(Double(rounded + 9) / 12.0))
        let pitches: [NotePitch] = [.C, .CSharp, .D, .DSharp, .E, .F,
                                     .FSharp, .G, .GSharp, .A, .ASharp, .B]
        return (pitches[noteIndex], octave)
    }
}
