import Foundation
import CoreGraphics
import AVFoundation

// MARK: - Paper Piano Key

struct PaperPianoKey: Identifiable {
    let id: Int
    let note: NotePitch
    let octave: Int
    let isBlack: Bool
    let whiteKeyIndex: Int       // index among white keys (0–14); black keys share the left white's index
    let blackKeyOffset: Double   // 0 = not black; 0.5–0.75 = fraction across the white key gap

    // Normalized frame within the keyboard rectangle (0…1 in both axes)
    // Set after calibration
    var normalizedFrame: CGRect = .zero

    var displayName: String { "\(note.rawValue)\(octave)" }
    var frequency: Double {
        let semitones = Double(note.semitoneOffset) + Double((octave - 4) * 12)
        return 440.0 * pow(2.0, semitones / 12.0)
    }

    // MARK: - Static layout for 2 octaves C3–C5

    static let layout: [PaperPianoKey] = {
        // White keys: C3–C6 (22 white keys, 3 full octaves + top C)
        let whites: [(NotePitch, Int)] = [
            (.C,3),(.D,3),(.E,3),(.F,3),(.G,3),(.A,3),(.B,3),
            (.C,4),(.D,4),(.E,4),(.F,4),(.G,4),(.A,4),(.B,4),
            (.C,5),(.D,5),(.E,5),(.F,5),(.G,5),(.A,5),(.B,5),
            (.C,6)
        ]
        // Black keys: (pitch, octave, leftWhiteIndex)
        let blacks: [(NotePitch, Int, Int)] = [
            (.CSharp,3,0), (.DSharp,3,1), (.FSharp,3,3), (.GSharp,3,4), (.ASharp,3,5),
            (.CSharp,4,7), (.DSharp,4,8), (.FSharp,4,10),(.GSharp,4,11),(.ASharp,4,12),
            (.CSharp,5,14),(.DSharp,5,15),(.FSharp,5,17),(.GSharp,5,18),(.ASharp,5,19),
        ]

        var keys: [PaperPianoKey] = []
        var id = 0

        // Add white keys first
        for (i, (pitch, oct)) in whites.enumerated() {
            var k = PaperPianoKey(id: id, note: pitch, octave: oct,
                                   isBlack: false, whiteKeyIndex: i, blackKeyOffset: 0)
            // Normalized frame: evenly divide the width
            let fw = 1.0 / Double(whites.count)
            k.normalizedFrame = CGRect(x: fw * Double(i), y: 0, width: fw, height: 1.0)
            keys.append(k)
            id += 1
        }

        // Add black keys on top
        for (pitch, oct, leftIdx) in blacks {
            let fw = 1.0 / Double(whites.count)
            let bw = fw * 0.6          // black key is 60% of white width
            let bh = 0.62              // black key is 62% of keyboard height (from top)
            let bx = fw * Double(leftIdx) + fw - bw / 2.0  // centered at the gap

            var k = PaperPianoKey(id: id, note: pitch, octave: oct,
                                   isBlack: true, whiteKeyIndex: leftIdx, blackKeyOffset: 0.5)
            k.normalizedFrame = CGRect(x: bx, y: 1.0 - bh, width: bw, height: bh)
            keys.append(k)
            id += 1
        }

        return keys
    }()
}

// MARK: - Calibration State

struct KeyboardCalibration {
    /// The four corners of the printed keyboard in the camera preview's coordinate space.
    /// Order: topLeft, topRight, bottomLeft, bottomRight
    var corners: [CGPoint] = []
    var isCalibrated: Bool { corners.count == 4 }

    /// Given a normalized point within the keyboard (0…1 each axis),
    /// maps it to a point in the camera preview coordinate space.
    func previewPoint(from normalized: CGPoint, in previewSize: CGSize) -> CGPoint? {
        guard isCalibrated else { return nil }
        let tl = corners[0], tr = corners[1], bl = corners[2], br = corners[3]
        // Bilinear interpolation
        let tx = normalized.x, ty = 1.0 - normalized.y // flip Y so top of keyboard = y=1 in norm
        let top    = CGPoint(x: tl.x + (tr.x - tl.x) * tx, y: tl.y + (tr.y - tl.y) * tx)
        let bottom = CGPoint(x: bl.x + (br.x - bl.x) * tx, y: bl.y + (br.y - bl.y) * tx)
        let result = CGPoint(x: top.x + (bottom.x - top.x) * ty,
                             y: top.y + (bottom.y - top.y) * ty)
        return result
    }

    /// Maps a point in preview space to a normalized 0…1 keyboard coordinate.
    func normalizedPoint(from previewPt: CGPoint, previewSize: CGSize) -> CGPoint? {
        guard isCalibrated else { return nil }
        // Inverse bilinear — approximate using the bounding rect for now
        let xs = corners.map { $0.x }
        let ys = corners.map { $0.y }
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        guard maxX > minX, maxY > minY else { return nil }
        return CGPoint(
            x: (previewPt.x - minX) / (maxX - minX),
            y: (previewPt.y - minY) / (maxY - minY)
        )
    }

    /// Returns which piano key (if any) a preview-space touch point lands on.
    func key(at previewPt: CGPoint, previewSize: CGSize) -> PaperPianoKey? {
        guard let norm = normalizedPoint(from: previewPt, previewSize: previewSize) else { return nil }
        // Check black keys first (they sit on top)
        let blacks = PaperPianoKey.layout.filter { $0.isBlack }
        let whites = PaperPianoKey.layout.filter { !$0.isBlack }
        for key in blacks + whites {
            if key.normalizedFrame.contains(norm) { return key }
        }
        return nil
    }
}

// MARK: - Vision Detection Result

struct FingerDetectionResult {
    let fingerTips: [CGPoint]      // in normalized 0…1 camera coordinates
    let timestamp: TimeInterval
}

// MARK: - Active Note

struct ActiveNote: Identifiable, Equatable {
    let id = UUID()
    let key: PaperPianoKey
    let startTime: Date
    var velocity: Float = 0.8      // 0…1

    static func == (lhs: ActiveNote, rhs: ActiveNote) -> Bool {
        lhs.key.id == rhs.key.id
    }
}
