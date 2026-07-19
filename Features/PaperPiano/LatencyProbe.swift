import SwiftUI
import CoreMedia

// MARK: - Latency Probe (measurement build only)

/// Debug-only tap-to-sound latency instrumentation for the paper-instrument
/// pipeline. It answers the one question a sound-only instrument lives or dies on:
/// how long from a finger landing on a printed key to the note being dispatched?
///
/// The headline is `total = confirm + audioOut`, broken down so a *balanced*
/// tuning decision is possible (which knob buys the most latency for the least
/// trust cost) instead of guessing:
///   • pipeline — per-frame staleness: capture (sensor) → we get the frame.
///   • confirm  — the frame where a finger first lands on a key (sensor time)
///                → the note-on being dispatched. Includes the `keyConfirmFrames`
///                debounce, which is the accuracy↔latency dial.
///   • audioOut — device-reported output latency (buffer + hardware), dispatch → speaker.
///
/// All `record*` hooks run on the camera's video queue (single producer). Only the
/// published `snapshot` is pushed to the main actor, on a throttled cadence, for the
/// on-screen HUD. Flip `enabled` to false to make every hook a no-op and hide the HUD.
final class LatencyProbe: ObservableObject {
    static let shared = LatencyProbe()

    /// Master switch. Measurement builds only — set false to remove all overhead.
    static let enabled = true

    struct Stat: Equatable {
        var p50 = 0.0, p95 = 0.0, max = 0.0, count = 0
    }

    struct Snapshot: Equatable {
        var fps = 0.0             // achieved processed frames/sec (last 1s)
        var pipeline = Stat()     // capture → frame delivered (ms)
        var confirm = Stat()      // first contact → note-on dispatch (ms), incl. debounce
        var audioOutMs = 0.0      // device-reported output latency (ms)
        var notes = 0
        var keyConfirmFrames = 0
        var targetFps = 0
        var captureLabel = "—"    // e.g. "1280x720@60"

        var totalP50: Double { confirm.p50 + audioOutMs }
        var totalP95: Double { confirm.p95 + audioOutMs }
    }

    /// Read by the HUD; only ever written on main.
    @Published private(set) var snapshot = Snapshot()

    // Video-queue-owned rolling windows.
    private var pipeline: [Double] = []
    private var confirm: [Double] = []
    private var frameStamps: [Double] = []
    private var notes = 0
    private let cap = 300
    private var lastReport = 0.0
    private let reportInterval = 0.5

    // Static-ish config surfaced to the HUD (set once at session setup).
    private var audioOutMs = 0.0
    var keyConfirmFrames = 0
    var targetFps = 0
    var captureLabel = "—"

    /// Host-clock now, in seconds — the same time base as capture presentation
    /// timestamps, so the two can be differenced directly.
    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func setAudioOutputLatency(_ seconds: Double) { audioOutMs = max(0, seconds) * 1000 }

    /// One call per processed camera frame, from the video queue.
    func recordFrame(presentationTime: Double, hostNow: Double) {
        guard Self.enabled else { return }
        push(&pipeline, max(0, hostNow - presentationTime) * 1000)
        frameStamps.append(hostNow)
        if frameStamps.count > cap { frameStamps.removeFirst(frameStamps.count - cap) }
        if hostNow - lastReport >= reportInterval { publish(now: hostNow); lastReport = hostNow }
    }

    /// One call per note-on, from the video queue. `confirmSeconds` = host-now
    /// minus the presentation time of the frame the finger first landed on the key.
    func recordNote(confirmSeconds: Double) {
        guard Self.enabled else { return }
        push(&confirm, max(0, confirmSeconds) * 1000)
        notes += 1
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > cap { a.removeFirst(a.count - cap) }
    }

    private func publish(now: Double) {
        let recent = frameStamps.reduce(into: 0) { c, t in if t >= now - 1.0 { c += 1 } }
        var s = Snapshot()
        s.fps = Double(recent)
        s.pipeline = stat(pipeline)
        s.confirm = stat(confirm)
        s.audioOutMs = audioOutMs
        s.notes = notes
        s.keyConfirmFrames = keyConfirmFrames
        s.targetFps = targetFps
        s.captureLabel = captureLabel

        // Console line — a backup readout when the HUD isn't in view.
        print(String(format: "⏱ fps %.0f/%d | pipeline p50 %.0f | confirm p50 %.0f p95 %.0f max %.0f | audioOut %.0f | TOTAL p50 %.0f p95 %.0f ms | notes %d | kcf %d @ %@",
                     s.fps, s.targetFps, s.pipeline.p50,
                     s.confirm.p50, s.confirm.p95, s.confirm.max,
                     s.audioOutMs, s.totalP50, s.totalP95, s.notes,
                     s.keyConfirmFrames, s.captureLabel))

        DispatchQueue.main.async { self.snapshot = s }
    }

    private func stat(_ raw: [Double]) -> Stat {
        guard !raw.isEmpty else { return Stat() }
        let s = raw.sorted()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(p * Double(s.count)))] }
        return Stat(p50: pct(0.5), p95: pct(0.95), max: s.last ?? 0, count: s.count)
    }
}

// MARK: - On-device HUD

/// Compact heads-up readout of the latency probe, overlaid on the play screen so
/// the numbers are legible on the device itself (Xcode-console reading isn't always
/// available). Only shown while `LatencyProbe.enabled`.
struct LatencyHUD: View {
    @ObservedObject var probe = LatencyProbe.shared

    var body: some View {
        let s = probe.snapshot
        VStack(alignment: .leading, spacing: 3) {
            Text("⏱ tap → sound").font(.system(size: 11, weight: .bold, design: .monospaced))
            row("total", fmt(s.totalP50, s.totalP95), tint: totalColor(s.totalP50))
            row("confirm", fmt(s.confirm.p50, s.confirm.p95))
            row("pipeline", String(format: "%.0f ms", s.pipeline.p50))
            row("audio out", String(format: "%.0f ms", s.audioOutMs))
            Divider().overlay(Color.white.opacity(0.25))
            row("fps", String(format: "%.0f / %d", s.fps, s.targetFps))
            row("confirm frames", "\(s.keyConfirmFrames)")
            row("notes", "\(s.notes)")
            Text(s.captureLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ key: String, _ value: String, tint: Color = .white) -> some View {
        HStack(spacing: 12) {
            Text(key).foregroundColor(.white.opacity(0.7))
            Spacer(minLength: 8)
            Text(value).foregroundColor(tint)
        }
    }

    private func fmt(_ p50: Double, _ p95: Double) -> String {
        String(format: "%.0f / %.0f ms", p50, p95)
    }

    /// Green under a playable ~70ms, amber to ~120ms, red beyond — a rough
    /// at-a-glance verdict, not a hard threshold.
    private func totalColor(_ ms: Double) -> Color {
        switch ms {
        case ..<70: return .green
        case ..<120: return .yellow
        default: return .red
        }
    }
}
