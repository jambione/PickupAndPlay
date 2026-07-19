import Foundation

// MARK: - Press Log (diagnostic capture)

/// Debug-only capture of every note trigger and calibration event to a file we
/// can pull off the device (`Documents/tapnote_presslog.txt`) to diagnose the
/// key→sound mapping. Each line records enough to reconstruct exactly where a
/// finger was and which key/note it resolved to, so a systematic offset (wrong
/// note by N keys, a mirror, edge drift) is visible in the data.
///
/// Flip `enabled` off to disable capture entirely.
final class PressLog {
    static let shared = PressLog()
    static let enabled = true

    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tapnote_presslog.txt")
    private let queue = DispatchQueue(label: "com.tapnote.presslog")
    private var handle: FileHandle?

    private init() {
        guard Self.enabled else { return }
        try? "TapNote press log — session \(Date())\n".write(to: url, atomically: true, encoding: .utf8)
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func log(_ line: String) {
        guard Self.enabled else { return }
        print("🎯 " + line)   // console fallback
        let stamped = String(format: "%.3f %@\n", Date().timeIntervalSince1970, line)
        queue.async { [weak self] in self?.handle?.write(Data(stamped.utf8)) }
    }
}
