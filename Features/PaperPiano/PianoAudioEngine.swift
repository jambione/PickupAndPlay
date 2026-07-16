import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Piano Audio Engine

/// Singleton audio engine that produces rich piano-like tones.
/// Uses AVAudioUnitSampler (General MIDI piano) when available,
/// falls back to a multi-oscillator additive synthesis engine.
class PianoAudioEngine {

    static let shared = PianoAudioEngine()

    // MARK: Private

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let reverb  = AVAudioUnitReverb()
    private let eq      = AVAudioUnitEQ(numberOfBands: 3)
    private var synthNodes: [Int: AVAudioPlayerNode] = [:]
    private var usingSampler = false
    private let audioQueue = DispatchQueue(label: "com.tapnote.audio", qos: .userInteractive)

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
            loadGeneralMIDIPiano()
        } catch {
            print("Audio engine start error: \(error)")
        }
    }

    private func setupAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    // MARK: - MIDI Piano Loading

    private func loadGeneralMIDIPiano() {
        // Load the built-in General MIDI soundbank
        // MIDI program 0 = Acoustic Grand Piano
        do {
            try sampler.loadSoundBankInstrument(
                at: generalMIDISoundbankURL(),
                program: 0,
                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB)
            )
            usingSampler = true
            print("✅ MIDI piano sampler loaded")
        } catch {
            print("MIDI sampler failed (\(error)), falling back to synthesis")
            usingSampler = false
        }
    }

    private func generalMIDISoundbankURL() -> URL {
        // macOS / iOS both ship a default DLS soundbank
        #if os(macOS)
        return URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        #else
        return URL(fileURLWithPath: "/System/Library/Audio/Sounds/MusicalInstruments")
        #endif
    }

    // MARK: - Play Note

    func playNote(key: PaperPianoKey, velocity: Float = 0.8) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let midiNote = self.midiNoteNumber(for: key)
            let midiVelocity = UInt8(min(127, Int(velocity * 127)))

            if self.usingSampler {
                self.sampler.startNote(midiNote, withVelocity: midiVelocity, onChannel: 0)

                // Schedule note-off after 1.2 seconds
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.sampler.stopNote(midiNote, onChannel: 0)
                }
            } else {
                self.playSynthNote(key: key, velocity: velocity)
            }
        }
    }

    func stopNote(key: PaperPianoKey) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let midiNote = self.midiNoteNumber(for: key)
            if self.usingSampler {
                self.sampler.stopNote(midiNote, onChannel: 0)
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
        let duration = 1.4
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
            let decay  = exp(-t * (3.5 + freq / 2000)) // frequency-dependent decay
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
            self?.engine.detach(player)
        }
    }
}
