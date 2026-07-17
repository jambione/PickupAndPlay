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

    // MARK: - Static layout for 3 octaves C3–C6 (matches the 3-octave printed PDF)

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

    /// Fast lookup by key id (ids are assigned sequentially from 0 in `layout`).
    static let byID: [Int: PaperPianoKey] = Dictionary(
        uniqueKeysWithValues: layout.map { ($0.id, $0) })
}

// MARK: - Calibration State

struct KeyboardCalibration {
    /// The four corners of the printed keyboard in the camera preview's coordinate space.
    /// Order: topLeft, topRight, bottomLeft, bottomRight.
    /// Writes go through `setCorners(_:)` so the homographies stay cached.
    private(set) var corners: [CGPoint] = []
    var isCalibrated: Bool { corners.count == 4 }

    // Solved once per corner update instead of per fingertip query (up to 10×/frame).
    private var cachedH: [Double]?      // camera → keyboard
    private var cachedInvH: [Double]?   // keyboard → camera

    init() {}

    mutating func setCorners(_ newCorners: [CGPoint]) {
        corners = newCorners
        cachedH = Self.cameraToKeyboardHomography(corners: newCorners)
        cachedInvH = Self.keyboardToCameraHomography(corners: newCorners)
    }

    /// Maps a point in camera/preview space to normalized 0…1 keyboard coordinates,
    /// applying a full perspective (keystone) correction from the 4 calibration
    /// corners. This "straightens out" a keyboard the camera sees at an angle, so a
    /// fingertip anywhere on the skewed paper lands on the correct key.
    ///
    /// `previewPt` may be given either already-normalized (with `previewSize` = 1×1,
    /// as the finger tracker does) or in view points (with the real preview size, as
    /// tap input does); it is normalized to the same 0…1 space as `corners` first.
    func normalizedPoint(from previewPt: CGPoint, previewSize: CGSize) -> CGPoint? {
        guard let h = cachedH, previewSize.width > 0, previewSize.height > 0 else { return nil }
        let p = CGPoint(x: previewPt.x / previewSize.width,
                        y: previewPt.y / previewSize.height)
        return Self.apply(h, to: p)
    }

    /// Inverse mapping: a normalized keyboard-space point (0…1) → normalized
    /// camera/preview space. Used to project key outlines onto the camera feed.
    func previewPoint(fromKeyboard pt: CGPoint) -> CGPoint? {
        guard let h = cachedInvH else { return nil }
        return Self.apply(h, to: pt)
    }

    // MARK: - Perspective (homography) mapping

    /// Keyboard space: x 0→1 left→right, y 0→1 front→back (black keys near y=1).
    private static let unitKeyboardCorners = [
        CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)
    ]

    /// Homography mapping the camera's (possibly skewed) keyboard quad → the unit
    /// keyboard rectangle. Corners are re-ordered to TL, TR, BL, BR so the result is
    /// robust to the order they were captured/tapped in.
    private static func cameraToKeyboardHomography(corners: [CGPoint]) -> [Double]? {
        guard let c = orderedCorners(corners) else { return nil }
        return solveHomography(src: c, dst: unitKeyboardCorners)
    }

    /// Inverse: unit keyboard rectangle → camera quad.
    private static func keyboardToCameraHomography(corners: [CGPoint]) -> [Double]? {
        guard let c = orderedCorners(corners) else { return nil }
        return solveHomography(src: unitKeyboardCorners, dst: c)
    }

    /// Sorts 4 points into [topLeft, topRight, bottomLeft, bottomRight]
    /// (preview space has y increasing downward, so smaller y = top).
    private static func orderedCorners(_ pts: [CGPoint]) -> [CGPoint]? {
        guard pts.count == 4 else { return nil }
        let byY = pts.sorted { $0.y < $1.y }
        let top = Array(byY.prefix(2)).sorted { $0.x < $1.x }
        let bottom = Array(byY.suffix(2)).sorted { $0.x < $1.x }
        return [top[0], top[1], bottom[0], bottom[1]]
    }

    /// Solves the 8 homography parameters [a,b,c,d,e,f,g,h] mapping src→dst (h33 = 1).
    private static func solveHomography(src: [CGPoint], dst: [CGPoint]) -> [Double]? {
        guard src.count == 4, dst.count == 4 else { return nil }
        var A = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var b = [Double](repeating: 0, count: 8)
        for i in 0..<4 {
            let sx = Double(src[i].x), sy = Double(src[i].y)
            let dx = Double(dst[i].x), dy = Double(dst[i].y)
            A[2 * i]     = [sx, sy, 1, 0, 0, 0, -sx * dx, -sy * dx]; b[2 * i]     = dx
            A[2 * i + 1] = [0, 0, 0, sx, sy, 1, -sx * dy, -sy * dy]; b[2 * i + 1] = dy
        }
        return gaussianSolve(A: &A, b: &b)
    }

    /// Applies homography `h` to point `p`, returning nil if projectively degenerate.
    private static func apply(_ h: [Double], to p: CGPoint) -> CGPoint? {
        let x = Double(p.x), y = Double(p.y)
        let denom = h[6] * x + h[7] * y + 1
        guard abs(denom) > 1e-9 else { return nil }
        return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / denom,
                       y: (h[3] * x + h[4] * y + h[5]) / denom)
    }

    /// Gaussian elimination with partial pivoting for a small dense system.
    private static func gaussianSolve(A: inout [[Double]], b: inout [Double]) -> [Double]? {
        let n = b.count
        for col in 0..<n {
            var pivot = col
            var maxVal = abs(A[col][col])
            for r in (col + 1)..<n where abs(A[r][col]) > maxVal {
                maxVal = abs(A[r][col]); pivot = r
            }
            guard maxVal > 1e-12 else { return nil }
            if pivot != col { A.swapAt(col, pivot); b.swapAt(col, pivot) }
            for r in (col + 1)..<n {
                let factor = A[r][col] / A[col][col]
                if factor == 0 { continue }
                for c in col..<n { A[r][c] -= factor * A[col][c] }
                b[r] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for c in (row + 1)..<n { sum -= A[row][c] * x[c] }
            x[row] = sum / A[row][row]
        }
        return x
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

// MARK: - Finger Overlay Frame

/// One fingertip as rendered by the camera overlay.
struct FingerDot: Identifiable {
    let id: Int                    // stable per tracked finger
    let location: CGPoint          // normalized 0…1 camera coordinates
    let isPressed: Bool            // currently sounding a note
}

/// A per-frame snapshot of all tracked fingertips, published as one unit so only
/// the lightweight overlay view re-renders at camera frame rate.
struct OverlayFrame {
    let fingers: [FingerDot]
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
