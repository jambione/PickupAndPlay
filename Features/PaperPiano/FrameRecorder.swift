import Foundation
import AVFoundation
import CoreMedia

// MARK: - Frame Recorder (diagnostic capture)

/// Debug-only recording of the raw camera frames the detector sees, written as
/// H.264 to `Documents/tapnote_capture.mov` so it can be pulled off the device
/// (same devicectl path as the press log) and lined up with `PressLog` events.
///
/// Sync contract: on the first written frame a `VIDEO start anchorEpoch=…` line
/// goes into the press log. Any log event at epoch E sits at video time
/// `E − anchorEpoch`. Capture PTS is host-clock time, so the anchor is computed
/// from the first frame's own PTS (not "now"), making the alignment frame-accurate.
///
/// Recording starts at the first calibrated frame (play begins), writes every
/// `frameStride`-th frame (60 → 30 fps) at a modest bitrate, caps at
/// `maxDuration`, and uses movie fragments so a file cut short by an app kill
/// stays playable. Flip `enabled` off to remove entirely.
final class FrameRecorder {
    static let shared = FrameRecorder()
    static let enabled = true

    private let maxDuration: Double = 180   // seconds — bounds the file (~65 MB)
    private let frameStride = 2             // write every Nth camera frame
    private let bitRate = 3_000_000

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startPTS: CMTime?
    private var frameCount = 0
    private var finished = false

    var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tapnote_capture.mov")
    }

    /// Called on the camera's video queue with every frame while calibrated.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard Self.enabled, !finished else { return }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if writer == nil { start(with: pixel, pts: pts) }
        guard let writer, let input, let adaptor, let startPTS else { return }

        let t = CMTimeSubtract(pts, startPTS)
        if t.seconds > maxDuration { finish(); return }

        frameCount += 1
        guard frameCount % frameStride == 0 else { return }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        adaptor.append(pixel, withPresentationTime: t)
    }

    private func start(with pixel: CVPixelBuffer, pts: CMTime) {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp,
                                                      sourcePixelBufferAttributes: nil)
        guard w.canAdd(inp) else { return }
        w.add(inp)
        // Fragmented movie: a session that never reaches finish() (app killed,
        // battery) still yields a playable file up to the last fragment.
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard w.startWriting() else { return }
        w.startSession(atSourceTime: .zero)
        writer = w; input = inp; adaptor = ad; startPTS = pts

        // PTS is host-clock seconds; anchor video t=0 to wall-clock epoch exactly.
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let anchorEpoch = Date().timeIntervalSince1970 - (hostNow - pts.seconds)
        PressLog.shared.log(String(format: "VIDEO start anchorEpoch=%.3f %dx%d stride=%d file=%@",
                                   anchorEpoch, width, height, frameStride, url.lastPathComponent))
    }

    /// Finalizes the file (idempotent). Called when the camera stops.
    func finish() {
        guard Self.enabled, let writer, !finished else { return }
        finished = true
        input?.markAsFinished()
        writer.finishWriting {}
        PressLog.shared.log("VIDEO finished")
    }
}
