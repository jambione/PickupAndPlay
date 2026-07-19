import Foundation
import AVFoundation
import Combine

// MARK: - Custom Sample Recorder

/// Records a short mic sample and hands it to `PianoAudioEngine` as the custom
/// "My Sample" voice — one re-recordable sample, persisted to Documents so it
/// survives relaunch. Publishes the state the record UI binds to.
///
/// Recording needs the `.playAndRecord` session category, which conflicts with
/// the low-latency `.playback` session the synth plays through — so the engine
/// swaps categories around each capture (`setRecordingSession`) and swaps back.
final class CustomSampleRecorder: NSObject, ObservableObject {
    static let shared = CustomSampleRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var hasSample = false
    @Published private(set) var isCustomVoiceSelected = false
    @Published var permissionDenied = false

    /// Longest sample kept — enough for a note or a word, short enough to feel snappy.
    private let maxDuration: TimeInterval = 4.0
    private var recorder: AVAudioRecorder?

    private var sampleURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom_sample.caf")
    }

    private override init() {
        super.init()
        // Reload a previously recorded sample so "My Sample" survives relaunch.
        if FileManager.default.fileExists(atPath: sampleURL.path) {
            hasSample = PianoAudioEngine.shared.loadCustomSample(url: sampleURL)
        }
    }

    // MARK: Intent

    func toggle() { isRecording ? finish() : start() }

    func start() {
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.permissionDenied = true; return }
            self.beginRecording()
        }
    }

    func finish() { recorder?.stop() }   // fires the delegate callback

    func selectCustomVoice() {
        PianoAudioEngine.shared.selectCustomSample()
        isCustomVoiceSelected = true
    }

    /// The picker calls this before loading a GM instrument, so the "My Sample"
    /// chip visually deselects (the engine switch itself is the picker's job).
    func deselectCustomVoice() { isCustomVoiceSelected = false }

    // MARK: Private

    private func beginRecording() {
        PianoAudioEngine.shared.setRecordingSession(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            try? FileManager.default.removeItem(at: sampleURL)
            let r = try AVAudioRecorder(url: sampleURL, settings: settings)
            r.delegate = self
            guard r.record(forDuration: maxDuration) else {
                PianoAudioEngine.shared.setRecordingSession(false); return
            }
            recorder = r
            isRecording = true
        } catch {
            print("recorder init error: \(error)")
            PianoAudioEngine.shared.setRecordingSession(false)
        }
    }

    private func requestPermission(_ done: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { done(granted) }
        }
        #else
        done(true)
        #endif
    }
}

// MARK: - AVAudioRecorderDelegate

extension CustomSampleRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.recorder = nil
            PianoAudioEngine.shared.setRecordingSession(false)
            guard flag, PianoAudioEngine.shared.loadCustomSample(url: self.sampleURL) else { return }
            self.hasSample = true
            self.selectCustomVoice()   // auto-play the sound you just made
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.recorder = nil
            PianoAudioEngine.shared.setRecordingSession(false)
        }
    }
}
