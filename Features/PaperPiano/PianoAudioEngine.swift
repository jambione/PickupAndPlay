import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Instrument Presets

/// Curated instruments, each mapping to a General MIDI program in the bundled
/// SoundFont plus a tailored effects profile.
enum InstrumentPreset: String, CaseIterable, Identifiable {
    case grandPiano, electricPiano, pipeOrgan, synthLead, strings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grandPiano:    return "Grand Piano"
        case .electricPiano: return "E-Piano"
        case .pipeOrgan:     return "Pipe Organ"
        case .synthLead:     return "Synth"
        case .strings:       return "Strings"
        }
    }

    var sfSymbol: String {
        switch self {
        case .grandPiano:    return "pianokeys"
        case .electricPiano: return "pianokeys.inverse"
        case .pipeOrgan:     return "building.columns.fill"
        case .synthLead:     return "waveform"
        case .strings:       return "music.quarternote.3"
        }
    }

    /// General MIDI program number.
    var gmProgram: UInt8 {
        switch self {
        case .grandPiano:    return 0    // Acoustic Grand Piano
        case .electricPiano: return 4    // Electric Piano 1
        case .pipeOrgan:     return 19   // Church Organ
        case .synthLead:     return 81   // Lead 2 (sawtooth)
        case .strings:       return 48   // String Ensemble 1
        }
    }

    var reverbMix: Float {
        switch self {
        case .grandPiano:    return 18
        case .electricPiano: return 22
        case .pipeOrgan:     return 35
        case .synthLead:     return 15
        case .strings:       return 40
        }
    }

    /// Gains for the 3-band EQ (low shelf 200 Hz, parametric 2.5 kHz, high shelf 8 kHz).
    var eqGains: (low: Float, mid: Float, high: Float) {
        switch self {
        case .grandPiano:    return (2.0, -1.5, -3.0)
        case .electricPiano: return (1.5, 0.0, -1.0)
        case .pipeOrgan:     return (3.0, -1.0, -2.0)
        case .synthLead:     return (0.0, 1.0, 1.5)
        case .strings:       return (1.0, -1.0, 0.0)
        }
    }

    /// Whether the sound sustains while held (organ/strings/synth) rather than
    /// decaying naturally like a struck piano.
    var sustains: Bool {
        switch self {
        case .grandPiano, .electricPiano: return false
        case .pipeOrgan, .synthLead, .strings: return true
        }
    }

    /// Decay time-constant multiplier for the additive-synth fallback.
    var synthDecayFactor: Double {
        sustains ? 0.35 : 1.0
    }
}

// MARK: - Piano Audio Engine

/// Singleton audio engine that produces rich instrument tones.
/// Uses AVAudioUnitSampler with the bundled GeneralUser GS SoundFont when
/// available (system DLS bank on Mac Catalyst as a fallback), and falls back
/// to a multi-oscillator additive synthesis engine as a last resort.
class PianoAudioEngine {

    static let shared = PianoAudioEngine()

    // MARK: Private

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let reverb  = AVAudioUnitReverb()
    private let eq      = AVAudioUnitEQ(numberOfBands: 3)
    private var usingSampler = false
    private let audioQueue = DispatchQueue(label: "com.tapnote.audio", qos: .userInteractive)

    /// MIDI notes currently sounding (audioQueue-only) — silenced on instrument switch.
    private var soundingNotes: Set<UInt8> = []

    /// The active instrument (audioQueue-only; UI keeps its own selection state).
    private(set) var currentPreset: InstrumentPreset = .grandPiano

    // MARK: - Init

    private init() {
        setupEngine()
    }

    private func setupEngine() {
        setupAudioSession()

        // Graph: sampler → reverb → eq → mainMixer → output
        engine.attach(sampler)
        engine.attach(reverb)
        engine.attach(eq)

        engine.connect(sampler, to: reverb, format: nil)
        engine.connect(reverb, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)

        // Reverb — small hall for warmth
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 18.0

        // EQ — slight low mid boost, high roll-off for warmth
        if eq.bands.count >= 3 {
            eq.bands[0].filterType = .lowShelf
            eq.bands[0].frequency = 200
            eq.bands[0].gain = 2.0
            eq.bands[0].bypass = false

            eq.bands[1].filterType = .parametric
            eq.bands[1].frequency = 2500
            eq.bands[1].bandwidth = 1.0
            eq.bands[1].gain = -1.5
            eq.bands[1].bypass = false

            eq.bands[2].filterType = .highShelf
            eq.bands[2].frequency = 8000
            eq.bands[2].gain = -3.0
            eq.bands[2].bypass = false
        }

        do {
            try engine.start()
            loadInstrument(.grandPiano)
        } catch {
            print("Audio engine start error: \(error)")
        }
    }

    private func setupAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        // Low-latency I/O so notes speak as soon as a finger lands.
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setPreferredSampleRate(48_000)
        try? session.setActive(true)
        #endif
    }

    // MARK: - Instrument Loading

    /// Switches the sampler to `preset`, silencing anything currently sounding
    /// and applying the preset's effects profile.
    func loadInstrument(_ preset: InstrumentPreset) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            // Silence held notes so nothing hangs across the program change.
            for note in self.soundingNotes { self.sampler.stopNote(note, onChannel: 0) }
            self.soundingNotes.removeAll()
            self.currentPreset = preset

            if let bank = self.soundbankURL() {
                do {
                    try self.sampler.loadSoundBankInstrument(
                        at: bank,
                        program: preset.gmProgram,
                        bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                        bankLSB: UInt8(kAUSampler_DefaultBankLSB)
                    )
                    self.usingSampler = true
                    print("✅ Sampler loaded: \(preset.displayName) from \(bank.lastPathComponent)")
                } catch {
                    print("Sampler failed for \(preset.displayName) (\(error)), falling back to synthesis")
                    self.usingSampler = false
                }
            } else {
                print("No soundbank available, using synthesis")
                self.usingSampler = false
            }

            // Effects profile
            self.reverb.wetDryMix = preset.reverbMix
            if self.eq.bands.count >= 3 {
                let g = preset.eqGains
                self.eq.bands[0].gain = g.low
                self.eq.bands[1].gain = g.mid
                self.eq.bands[2].gain = g.high
            }
        }
    }

    /// Bundled GeneralUser GS SoundFont, else the system GM bank on Mac.
    private func soundbankURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "GeneralUserGS", withExtension: "sf2") {
            return bundled
        }
        #if targetEnvironment(macCatalyst) || os(macOS)
        let dls = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        if FileManager.default.fileExists(atPath: dls.path) { return dls }
        #endif
        return nil
    }

    // MARK: - Play Note

    func playNote(key: PaperPianoKey, velocity: Float = 0.8) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let midiNote = self.midiNoteNumber(for: key)
            let midiVelocity = UInt8(min(127, Int(velocity * 127)))

            if self.usingSampler {
                self.sampler.startNote(midiNote, withVelocity: midiVelocity, onChannel: 0)
                self.soundingNotes.insert(midiNote)

                // Schedule note-off after 1.2 seconds
                self.audioQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.sampler.stopNote(midiNote, onChannel: 0)
                    self?.soundingNotes.remove(midiNote)
                }
            } else {
                self.playSynthNote(key: key, velocity: velocity)
            }
        }
    }

    /// Note-on for a sustained press. Unlike `playNote` there is no scheduled
    /// note-off — the note rings until `stopNote(key:)` is called (finger lift).
    /// The synthesis fallback can't be sustained, so it plays its usual decay.
    func holdNote(key: PaperPianoKey, velocity: Float = 0.8) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            if self.usingSampler {
                let midiNote = self.midiNoteNumber(for: key)
                let midiVelocity = UInt8(min(127, Int(velocity * 127)))
                self.sampler.startNote(midiNote, withVelocity: midiVelocity, onChannel: 0)
                self.soundingNotes.insert(midiNote)
            } else {
                self.playSynthNote(key: key, velocity: velocity)
            }
        }
    }

    /// Quick C-E-G arpeggio confirming the keyboard locked on.
    func playCalibrationCue() {
        let cue: [(NotePitch, Int)] = [(.C, 4), (.E, 4), (.G, 4)]
        for (i, (pitch, octave)) in cue.enumerated() {
            guard let key = PaperPianoKey.layout.first(where: { $0.note == pitch && $0.octave == octave })
            else { continue }
            audioQueue.asyncAfter(deadline: .now() + Double(i) * 0.12) { [weak self] in
                self?.playNote(key: key, velocity: 0.7)
            }
        }
    }

    func stopNote(key: PaperPianoKey) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let midiNote = self.midiNoteNumber(for: key)
            if self.usingSampler {
                self.sampler.stopNote(midiNote, onChannel: 0)
                self.soundingNotes.remove(midiNote)
            }
        }
    }

    // MARK: - MIDI Note Number

    private func midiNoteNumber(for key: PaperPianoKey) -> UInt8 {
        // MIDI: C4 = 60, each semitone = +1
        let base = (key.octave + 1) * 12
        let offset: Int
        switch key.note {
        case .C:      offset = 0
        case .CSharp: offset = 1
        case .D:      offset = 2
        case .DSharp: offset = 3
        case .E:      offset = 4
        case .F:      offset = 5
        case .FSharp: offset = 6
        case .G:      offset = 7
        case .GSharp: offset = 8
        case .A:      offset = 9
        case .ASharp: offset = 10
        case .B:      offset = 11
        }
        return UInt8(clamping: base + offset)
    }

    // MARK: - Additive Synthesis Fallback

    private func playSynthNote(key: PaperPianoKey, velocity: Float) {
        let freq = key.frequency
        // Sustaining presets (organ/strings/synth) get a slower decay.
        let decayFactor = currentPreset.synthDecayFactor
        let duration = decayFactor < 1.0 ? 2.8 : 1.4
        let sampleRate = 44100.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!,
            frameCapacity: frameCount
        ) else { return }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else { return }

        // Piano-like additive synthesis:
        // Fundamental + harmonics with piano-characteristic decay
        let harmonics: [(multiplier: Double, amplitude: Float)] = [
            (1.0, 1.0),
            (2.0, 0.45),
            (3.0, 0.20),
            (4.0, 0.12),
            (5.0, 0.07),
            (6.0, 0.04),
            (7.0, 0.025),
            (8.0, 0.015),
        ]

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            // Fast attack, longer release (piano-like)
            let attack = min(1.0, t * 200.0)           // ~5ms attack
            let decay  = exp(-t * (3.5 + freq / 2000) * decayFactor) // frequency-dependent decay
            let envelope = Float(attack) * Float(decay) * velocity

            var sample: Float = 0
            for h in harmonics {
                sample += h.amplitude * Float(sin(2.0 * .pi * freq * h.multiplier * t))
            }
            data[frame] = sample * envelope * 0.25
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: reverb, format: buffer.format)
        player.play()
        player.scheduleBuffer(buffer) { [weak self] in
            // This completion handler runs on AVAudioEngine's internal queue. Calling
            // detachNode() directly here re-enters that queue and traps (SIGTRAP:
            // "dispatch_sync called on queue already owned by current thread").
            // Hop onto our audio queue so the detach happens off the callback thread.
            self?.audioQueue.async { self?.engine.detach(player) }
        }
    }
}
