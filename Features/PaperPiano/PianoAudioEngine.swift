import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Instrument Presets

/// Curated instruments, each mapping to a General MIDI program in the bundled
/// SoundFont plus a tailored effects profile.
enum InstrumentPreset: String, CaseIterable, Identifiable {
    case grandPiano, electricPiano, pipeOrgan, synthLead, strings
    // Mallet/bell family (Paper Orchestra Phase 2) — same picker, no new UI;
    // these just add more GM timbres to choose from regardless of which
    // sheet (piano or mallet bars) is active.
    case xylophone, glockenspiel, vibraphone, marimba, tubularBells, handbells
    // Zither/harp family (Paper Orchestra Phase 3).
    case orchestralHarp
    // Bass family (bass-guitar sheet): shown in their own picker when the bass
    // sheet is active, hidden from the general melodic picker.
    case uprightBass, fingeredBass, pickedBass, fretlessBass, slapBass, synthBass

    var id: String { rawValue }

    /// The bass-guitar sheet's timbres (its picker filters on this).
    var isBass: Bool {
        switch self {
        case .uprightBass, .fingeredBass, .pickedBass,
             .fretlessBass, .slapBass, .synthBass: return true
        default: return false
        }
    }
    static var bassFamily: [InstrumentPreset] { allCases.filter(\.isBass) }

    var displayName: String {
        switch self {
        case .grandPiano:    return "Grand Piano"
        case .electricPiano: return "E-Piano"
        case .pipeOrgan:     return "Pipe Organ"
        case .synthLead:     return "Synth"
        case .strings:       return "Strings"
        case .xylophone:     return "Xylophone"
        case .glockenspiel:  return "Glockenspiel"
        case .vibraphone:    return "Vibraphone"
        case .marimba:       return "Marimba"
        case .tubularBells:  return "Tubular Bells"
        case .handbells:     return "Handbells"
        case .orchestralHarp: return "Harp"
        case .uprightBass:   return "Upright"
        case .fingeredBass:  return "Fingered"
        case .pickedBass:    return "Picked"
        case .fretlessBass:  return "Fretless"
        case .slapBass:      return "Slap"
        case .synthBass:     return "Synth Bass"
        }
    }

    var sfSymbol: String {
        switch self {
        case .grandPiano:    return "pianokeys"
        case .electricPiano: return "pianokeys.inverse"
        case .pipeOrgan:     return "building.columns.fill"
        case .synthLead:     return "waveform"
        case .strings:       return "music.quarternote.3"
        case .xylophone, .glockenspiel, .vibraphone, .marimba: return "music.note"
        case .tubularBells, .handbells: return "bell.fill"
        case .orchestralHarp: return "pianokeys"
        case .uprightBass, .fingeredBass, .pickedBass,
             .fretlessBass, .slapBass: return "guitars"
        case .synthBass:     return "waveform.path"
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
        case .xylophone:     return 13   // Xylophone
        case .glockenspiel:  return 9    // Glockenspiel
        case .vibraphone:    return 11   // Vibraphone
        case .marimba:       return 12   // Marimba
        case .tubularBells:  return 14   // Tubular Bells
        // 112 "Tinker Bell" — closest bundled proxy for handbells; some
        // SoundFont renderings of this GM slot lean more wind-chime than
        // church-handbell. Listen-test before advertising it as the real thing.
        case .handbells:     return 112
        case .orchestralHarp: return 46  // Orchestral Harp
        case .uprightBass:   return 32   // Acoustic Bass
        case .fingeredBass:  return 33   // Electric Bass (finger)
        case .pickedBass:    return 34   // Electric Bass (pick)
        case .fretlessBass:  return 35   // Fretless Bass
        case .slapBass:      return 36   // Slap Bass 1
        case .synthBass:     return 38   // Synth Bass 1
        }
    }

    var reverbMix: Float {
        switch self {
        case .grandPiano:    return 18
        case .electricPiano: return 22
        case .pipeOrgan:     return 35
        case .synthLead:     return 15
        case .strings:       return 40
        case .xylophone:     return 20
        case .glockenspiel:  return 28
        case .vibraphone:    return 32
        case .marimba:       return 22
        case .tubularBells:  return 38
        case .handbells:     return 34
        case .orchestralHarp: return 30
        // Bass wants presence, not wash — reverb muddies the low end fast.
        case .uprightBass:   return 14
        case .fingeredBass:  return 10
        case .pickedBass:    return 10
        case .fretlessBass:  return 18
        case .slapBass:      return 8
        case .synthBass:     return 12
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
        case .xylophone:     return (-1.0, 0.5, 2.0)
        case .glockenspiel:  return (-2.0, 0.5, 3.0)
        case .vibraphone:    return (0.0, 0.0, 1.5)
        case .marimba:       return (0.5, 0.0, 1.0)
        case .tubularBells:  return (0.0, 0.0, 2.0)
        case .handbells:     return (-1.0, 0.5, 2.5)
        case .orchestralHarp: return (0.5, 0.0, 1.5)
        // Low-shelf lift for body; slap/pick get mid/high presence for attack.
        case .uprightBass:   return (4.0, -0.5, -2.5)
        case .fingeredBass:  return (3.5, 0.0, -1.5)
        case .pickedBass:    return (3.0, 1.0, 0.5)
        case .fretlessBass:  return (3.5, 1.0, -1.0)
        case .slapBass:      return (3.0, 1.5, 1.5)
        case .synthBass:     return (4.5, 0.5, -0.5)
        }
    }

    /// Whether the sound sustains while held (organ/strings/synth) rather than
    /// decaying naturally like a struck piano. Governs only the additive-synth
    /// fallback's decay speed — the real sampled path always uses the
    /// SoundFont's own envelope regardless of this flag.
    var sustains: Bool {
        switch self {
        // A plucked harp/bass decays audibly like a struck mallet, not a bell's
        // long resonance or an organ's indefinite sustain.
        case .grandPiano, .electricPiano, .xylophone, .marimba, .orchestralHarp,
             .uprightBass, .fingeredBass, .pickedBass,
             .fretlessBass, .slapBass, .synthBass: return false
        case .pipeOrgan, .synthLead, .strings,
             .glockenspiel, .vibraphone, .tubularBells, .handbells: return true
        }
    }

    /// Decay time-constant multiplier for the additive-synth fallback.
    var synthDecayFactor: Double {
        sustains ? 0.35 : 1.0
    }
}

// MARK: - Drum Kit Presets

/// Percussion kits from the bundled SoundFont's GM percussion bank (bank 120).
/// Selected via a program change on MIDI channel 9 (the GM percussion
/// channel) — not a bank-select — confirmed by direct testing to route there
/// automatically on this synth with no other plumbing needed.
enum DrumKitPreset: String, CaseIterable, Identifiable {
    case standardKit, roomKit, jazzKit, electronicKit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standardKit:   return "Standard Kit"
        case .roomKit:       return "Room Kit"
        case .jazzKit:       return "Jazz Kit"
        case .electronicKit: return "Electronic Kit"
        }
    }

    var sfSymbol: String { "circle.grid.3x3.fill" }

    /// Program number within bank 120 (percussion), per the bundled SoundFont.
    var gmProgram: UInt8 {
        switch self {
        case .standardKit:   return 0   // "Standard 1 Kit"
        case .roomKit:       return 8   // "Room Kit"
        case .jazzKit:       return 32  // "Jazz Kit"
        case .electronicKit: return 24  // "Electronic Kit"
        }
    }
}

/// The MIDI channel General MIDI reserves for percussion (index 9, "channel 10").
private let percussionChannel: UInt8 = 9

// MARK: - Piano Audio Engine

/// Singleton audio engine that produces rich instrument tones.
///
/// Playback uses Apple's AUMIDISynth unit with the bundled GeneralUser GS
/// SoundFont (system DLS bank on Mac as a fallback). AUMIDISynth — not
/// AVAudioUnitSampler — because AUSampler is unreliable rendering third-party
/// SF2 sample loops (SIGSEGV in SamplerNote::Render reading past the end of
/// the mapped sample region), and because AUMIDISynth switches instruments
/// with plain MIDI program changes: no bank reloads at runtime at all.
/// Falls back to a multi-oscillator additive synthesis engine as a last resort.
class PianoAudioEngine {

    static let shared = PianoAudioEngine()

    // MARK: Private

    private let engine = AVAudioEngine()
    private let synthUnit: AVAudioUnitMIDIInstrument = {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: kAudioUnitSubType_MIDISynth,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        return AVAudioUnitMIDIInstrument(audioComponentDescription: description)
    }()
    private let reverb  = AVAudioUnitReverb()
    private let eq      = AVAudioUnitEQ(numberOfBands: 3)
    private var usingSampler = false
    private let audioQueue = DispatchQueue(label: "com.tapnote.audio", qos: .userInteractive)

    /// A separate sampler for the user's own recorded sample, loaded from a plain
    /// audio file (safe, unlike the third-party SF2 that crashes AUSampler — see
    /// the class note). Only ever carries the melodic voice; percussion (channel
    /// 9) always stays on `synthUnit`.
    private let customSampler = AVAudioUnitSampler()
    private var hasCustomSample = false      // audioQueue-only: a sample is loaded & playable
    private var usingCustomSample = false    // audioQueue-only: route melodic notes to customSampler

    /// A sounding MIDI note is only unique per (note, channel) — GM drum-map
    /// note numbers (channel 9/percussion) overlap the ordinary melodic note
    /// range (channel 0), so tracking bare note numbers would let a struck
    /// drum note collide with an unrelated melodic one of the same number.
    private struct SoundingNote: Hashable { let note: UInt8; let channel: UInt8 }

    /// Notes currently sounding (audioQueue-only) — silenced on instrument switch.
    private var soundingNotes: Set<SoundingNote> = []

    /// The active instrument (audioQueue-only; UI keeps its own selection state).
    private(set) var currentPreset: InstrumentPreset = .grandPiano

    /// The active drum kit (audioQueue-only; UI keeps its own selection state).
    private(set) var currentDrumKit: DrumKitPreset = .standardKit

    // MARK: - Init

    private init() {
        setupEngine()
    }

    private func setupEngine() {
        setupAudioSession()

        // Graph: synth → reverb → eq → mainMixer → output
        engine.attach(synthUnit)
        engine.attach(reverb)
        engine.attach(eq)

        engine.connect(synthUnit, to: reverb, format: nil)
        engine.connect(reverb, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)

        // The custom-sample voice runs on its own sampler, dry into the mixer.
        engine.attach(customSampler)
        engine.connect(customSampler, to: engine.mainMixerNode, format: nil)

        // Point the synth at its SoundFont before the engine initializes it.
        usingSampler = loadSoundBank()

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
            if usingSampler { preloadPrograms() }
            loadInstrument(.grandPiano)
            loadDrumKit(.standardKit)
        } catch {
            print("Audio engine start error: \(error)")
        }
    }

    private func setupAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        // Low-latency I/O so notes speak as soon as a finger lands. 44.1 kHz
        // matches the SoundFont's native sample rate (no live resampling).
        // 5 ms buffer: AUMIDISynth's render is light enough to fill it reliably.
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setPreferredSampleRate(44_100)
        try? session.setActive(true)
        // Report the audio tail (buffer + hardware) to the latency probe — the
        // dispatch→speaker leg the camera pipeline can't see. Valid once active.
        LatencyProbe.shared.setAudioOutputLatency(session.outputLatency + session.ioBufferDuration)
        #endif
    }

    // MARK: - SoundFont / Instrument Loading

    /// Hands the SoundFont to the synth (once, before rendering ever starts).
    private func loadSoundBank() -> Bool {
        guard let bank = soundbankURL() else {
            print("No soundbank available, using synthesis")
            return false
        }
        var bankRef = bank as CFURL   // the property expects a CFURL object reference
        let status = AudioUnitSetProperty(
            synthUnit.audioUnit,
            AudioUnitPropertyID(kMusicDeviceProperty_SoundBankURL),
            AudioUnitScope(kAudioUnitScope_Global),
            0, &bankRef, UInt32(MemoryLayout<CFURL>.size))
        if status != noErr {
            print("SoundBank load failed (\(status)), using synthesis")
            return false
        }
        print("✅ SoundFont attached: \(bank.lastPathComponent)")
        return true
    }

    /// AUMIDISynth loads a program's samples only when a program change arrives
    /// while "preload" is enabled — warm all presets once so switching is instant.
    private func preloadPrograms() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            var enabled: UInt32 = 1
            let propID = AudioUnitPropertyID(kAUMIDISynthProperty_EnablePreload)
            let scope = AudioUnitScope(kAudioUnitScope_Global)
            AudioUnitSetProperty(self.synthUnit.audioUnit, propID, scope, 0,
                                 &enabled, UInt32(MemoryLayout<UInt32>.size))
            for preset in InstrumentPreset.allCases {
                MusicDeviceMIDIEvent(self.synthUnit.audioUnit,
                                     0xC0, UInt32(preset.gmProgram), 0, 0)
            }
            for kit in DrumKitPreset.allCases {
                MusicDeviceMIDIEvent(self.synthUnit.audioUnit,
                                     0xC0 | UInt32(percussionChannel), UInt32(kit.gmProgram), 0, 0)
            }
            enabled = 0
            AudioUnitSetProperty(self.synthUnit.audioUnit, propID, scope, 0,
                                 &enabled, UInt32(MemoryLayout<UInt32>.size))
        }
    }

    /// Switches to `preset` with a plain MIDI program change (no bank reload),
    /// silencing anything currently sounding and applying the effects profile.
    func loadInstrument(_ preset: InstrumentPreset) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.currentPreset = preset

            self.reverb.wetDryMix = preset.reverbMix
            if self.eq.bands.count >= 3 {
                let g = preset.eqGains
                self.eq.bands[0].gain = g.low
                self.eq.bands[1].gain = g.mid
                self.eq.bands[2].gain = g.high
            }

            // Picking a GM instrument leaves the custom-sample voice; silence
            // whatever was ringing (on either instrument) so nothing hangs.
            self.usingCustomSample = false
            self.silenceAll()

            guard self.usingSampler else { return }
            self.synthUnit.sendProgramChange(preset.gmProgram, onChannel: 0)
            print("🎹 Instrument: \(preset.displayName) (program \(preset.gmProgram))")
        }
    }

    /// Switches the drum kit with a program change on the percussion channel
    /// only — deliberately scoped to channel 9 so switching kits doesn't cut
    /// off a currently-sustaining melodic note on channel 0.
    func loadDrumKit(_ preset: DrumKitPreset) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.currentDrumKit = preset
            guard self.usingSampler else { return }
            for sounding in self.soundingNotes where sounding.channel == percussionChannel {
                self.synthUnit.stopNote(sounding.note, onChannel: percussionChannel)
            }
            self.soundingNotes = self.soundingNotes.filter { $0.channel != percussionChannel }
            self.synthUnit.sendProgramChange(preset.gmProgram, onChannel: percussionChannel)
            print("🥁 Drum kit: \(preset.displayName) (program \(preset.gmProgram))")
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

    func playNote(key: PaperPianoKey, velocity: Float = 0.8, channel: UInt8 = 0) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let midiNote = self.midiNoteNumber(for: key)
            let midiVelocity = UInt8(min(127, Int(velocity * 127)))
            let sounding = SoundingNote(note: midiNote, channel: channel)

            guard let target = self.midiTarget(channel: channel) else {
                self.playSynthNote(key: key, velocity: velocity); return
            }
            // Re-striking a sounding note without a note-off stacks voices —
            // always release first.
            if self.soundingNotes.contains(sounding) { self.stopMidi(midiNote, channel: channel) }
            target.startNote(midiNote, withVelocity: midiVelocity, onChannel: channel)
            self.soundingNotes.insert(sounding)

            // Schedule note-off after 1.2 seconds
            self.audioQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.stopMidi(midiNote, channel: channel)
                self?.soundingNotes.remove(sounding)
            }
        }
    }

    /// Note-on for a sustained press. Unlike `playNote` there is no scheduled
    /// note-off — the note rings until `stopNote(key:)` is called (finger lift).
    /// The synthesis fallback can't be sustained, so it plays its usual decay.
    func holdNote(key: PaperPianoKey, velocity: Float = 0.8, channel: UInt8 = 0) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard let target = self.midiTarget(channel: channel) else {
                self.playSynthNote(key: key, velocity: velocity); return
            }
            let midiNote = self.midiNoteNumber(for: key)
            let midiVelocity = UInt8(min(127, Int(velocity * 127)))
            let sounding = SoundingNote(note: midiNote, channel: channel)
            if self.soundingNotes.contains(sounding) { self.stopMidi(midiNote, channel: channel) }
            target.startNote(midiNote, withVelocity: midiVelocity, onChannel: channel)
            self.soundingNotes.insert(sounding)
        }
    }

    /// Fire-and-forget note for struck/percussive zones (drums, mallets, plucked
    /// strings): plays once and lets the SoundFont's own sample decay handle the
    /// tail, with a longer safety auto-note-off than `playNote`'s 1.2s since
    /// cymbal/bell/resonant tails can ring considerably longer than a piano note.
    func playPercussiveNote(key: PaperPianoKey, velocity: Float = 0.8, channel: UInt8 = 0) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let midiNote = self.midiNoteNumber(for: key)
            let midiVelocity = UInt8(min(127, Int(velocity * 127)))
            let sounding = SoundingNote(note: midiNote, channel: channel)

            guard let target = self.midiTarget(channel: channel) else {
                self.playSynthNote(key: key, velocity: velocity); return
            }
            if self.soundingNotes.contains(sounding) { self.stopMidi(midiNote, channel: channel) }
            target.startNote(midiNote, withVelocity: midiVelocity, onChannel: channel)
            self.soundingNotes.insert(sounding)

            self.audioQueue.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.stopMidi(midiNote, channel: channel)
                self?.soundingNotes.remove(sounding)
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

    func stopNote(key: PaperPianoKey, channel: UInt8 = 0) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let midiNote = self.midiNoteNumber(for: key)
            self.stopMidi(midiNote, channel: channel)
            self.soundingNotes.remove(SoundingNote(note: midiNote, channel: channel))
        }
    }

    // MARK: - Custom Sample Voice

    /// The MIDI instrument a note should sound on. The custom sample only ever
    /// carries the melodic voice (channel 0); percussion stays on `synthUnit`.
    /// nil means neither path is available → additive-synth fallback.
    private func midiTarget(channel: UInt8) -> AVAudioUnitMIDIInstrument? {
        if usingCustomSample, hasCustomSample, channel != percussionChannel { return customSampler }
        if usingSampler { return synthUnit }
        return nil
    }

    /// Stops a note on both instruments — cheap, and avoids a hung note if the
    /// active voice changed while the note was still ringing.
    private func stopMidi(_ note: UInt8, channel: UInt8) {
        synthUnit.stopNote(note, onChannel: channel)
        customSampler.stopNote(note, onChannel: channel)
    }

    /// Silences everything on both instruments (used on any voice switch).
    private func silenceAll() {
        for s in soundingNotes { stopMidi(s.note, channel: s.channel) }
        soundingNotes.removeAll()
    }

    /// Loads a recorded audio file as the custom sampler instrument, pitch-mapped
    /// across the keyboard. Loading a plain audio file (not SF2) is the safe path.
    @discardableResult
    func loadCustomSample(url: URL) -> Bool {
        do {
            try customSampler.loadAudioFiles(at: [url])
            audioQueue.async { [weak self] in self?.hasCustomSample = true }
            return true
        } catch {
            print("custom sample load error: \(error)")
            return false
        }
    }

    /// Makes the loaded custom sample the active melodic voice.
    func selectCustomSample() {
        audioQueue.async { [weak self] in
            guard let self, self.hasCustomSample else { return }
            self.silenceAll()
            self.usingCustomSample = true
            print("🎙️ Voice: My Sample")
        }
    }

    /// Temporarily switches the audio session so the mic can be recorded, then
    /// restores the low-latency playback session. Restarts the engine if the
    /// category change stopped it.
    func setRecordingSession(_ recording: Bool) {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        if recording {
            try? s.setCategory(.playAndRecord, mode: .default,
                               options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        } else {
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setPreferredIOBufferDuration(0.01)
        }
        try? s.setActive(true)
        if !engine.isRunning { try? engine.start() }
        #endif
    }

    // MARK: - MIDI Note Number

    private func midiNoteNumber(for key: PaperPianoKey) -> UInt8 {
        // Non-piano zones (e.g. GM drum-map pads) address a specific MIDI note
        // directly — they aren't a musical pitch derived from note/octave.
        if let override = key.midiNoteOverride { return override }
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
