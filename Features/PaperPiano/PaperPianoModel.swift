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

    /// MIDI note number to send instead of the note/octave-derived default.
    /// Non-piano zones (drum pads, etc.) aren't really musical pitches — a
    /// kick drum has no "octave" — so this lets a zone address any MIDI note
    /// (e.g. the GM drum map) without distorting `note`/`octave`.
    var midiNoteOverride: UInt8? = nil

    /// Label to show instead of `note`+`octave` (e.g. "Kick", "Snare") for
    /// zones that aren't musical notes. `note`/`octave` still need placeholder
    /// values in that case (id/hashing/frequency don't depend on them being
    /// musically meaningful).
    var displayLabel: String? = nil

    var displayName: String { displayLabel ?? "\(note.rawValue)\(octave)" }
    var frequency: Double {
        let semitones = Double(note.semitoneOffset) + Double((octave - 4) * 12)
        return 440.0 * pow(2.0, semitones / 12.0)
    }

    // MARK: - Layouts (one per printed sheet variant)

    /// Builds a keyboard layout: whites evenly dividing the width, blacks on top.
    /// Proportions match a real piano (black ≈ 60% of white width, 62% of length),
    /// so the printed sheets can use true key dimensions.
    private static func makeLayout(whites: [(NotePitch, Int)],
                                   blacks: [(NotePitch, Int, Int)]) -> [PaperPianoKey] {
        var keys: [PaperPianoKey] = []
        var id = 0
        let fw = 1.0 / Double(whites.count)

        for (i, (pitch, oct)) in whites.enumerated() {
            var k = PaperPianoKey(id: id, note: pitch, octave: oct,
                                   isBlack: false, whiteKeyIndex: i, blackKeyOffset: 0)
            k.normalizedFrame = CGRect(x: fw * Double(i), y: 0, width: fw, height: 1.0)
            keys.append(k)
            id += 1
        }
        for (pitch, oct, leftIdx) in blacks {
            let bw = fw * 0.6
            let bh = 0.62
            let bx = fw * Double(leftIdx) + fw - bw / 2.0  // centered at the gap
            var k = PaperPianoKey(id: id, note: pitch, octave: oct,
                                   isBlack: true, whiteKeyIndex: leftIdx, blackKeyOffset: 0.5)
            k.normalizedFrame = CGRect(x: bx, y: 1.0 - bh, width: bw, height: bh)
            keys.append(k)
            id += 1
        }
        return keys
    }

    /// 3 octaves C3–C6: 22 white + 15 black keys.
    static let threeOctaveLayout: [PaperPianoKey] = makeLayout(
        whites: [
            (.C,3),(.D,3),(.E,3),(.F,3),(.G,3),(.A,3),(.B,3),
            (.C,4),(.D,4),(.E,4),(.F,4),(.G,4),(.A,4),(.B,4),
            (.C,5),(.D,5),(.E,5),(.F,5),(.G,5),(.A,5),(.B,5),
            (.C,6)
        ],
        blacks: [
            (.CSharp,3,0), (.DSharp,3,1), (.FSharp,3,3), (.GSharp,3,4), (.ASharp,3,5),
            (.CSharp,4,7), (.DSharp,4,8), (.FSharp,4,10),(.GSharp,4,11),(.ASharp,4,12),
            (.CSharp,5,14),(.DSharp,5,15),(.FSharp,5,17),(.GSharp,5,18),(.ASharp,5,19),
        ])

    /// 2 octaves C3–C5: 15 white + 10 black keys (true-size single-A3 sheet).
    static let twoOctaveLayout: [PaperPianoKey] = makeLayout(
        whites: [
            (.C,3),(.D,3),(.E,3),(.F,3),(.G,3),(.A,3),(.B,3),
            (.C,4),(.D,4),(.E,4),(.F,4),(.G,4),(.A,4),(.B,4),
            (.C,5)
        ],
        blacks: [
            (.CSharp,3,0), (.DSharp,3,1), (.FSharp,3,3), (.GSharp,3,4), (.ASharp,3,5),
            (.CSharp,4,7), (.DSharp,4,8), (.FSharp,4,10),(.GSharp,4,11),(.ASharp,4,12),
        ])

    /// 5-pad starter drum kit: Kick (front-center), Snare + Closed Hi-Hat
    /// (mid row), Crash + Floor Tom (back row) — a spatial arrangement, not
    /// an evenly-spaced row like piano/mallet zones. `note`/`octave` are
    /// unused placeholders (audio and display both go through the
    /// `midiNoteOverride`/`displayLabel` fields); GM drum-map note numbers.
    static let drumKitLayout: [PaperPianoKey] = {
        // (label, GM drum-map note, normalized rect)
        let pads: [(String, UInt8, CGRect)] = [
            ("Kick",      36, CGRect(x: 0.28, y: 0.03, width: 0.34, height: 0.28)),
            ("Hi-Hat",    42, CGRect(x: 0.08, y: 0.35, width: 0.28, height: 0.28)),
            ("Snare",     38, CGRect(x: 0.42, y: 0.35, width: 0.28, height: 0.28)),
            ("Crash",     49, CGRect(x: 0.03, y: 0.68, width: 0.30, height: 0.29)),
            ("Floor Tom", 41, CGRect(x: 0.67, y: 0.68, width: 0.30, height: 0.29)),
        ]
        return pads.enumerated().map { i, pad in
            var k = PaperPianoKey(id: i, note: .C, octave: 4,
                                  isBlack: false, whiteKeyIndex: i, blackKeyOffset: 0)
            k.normalizedFrame = pad.2
            k.midiNoteOverride = pad.1
            k.displayLabel = pad.0
            return k
        }
    }()

    /// Mallet/bell family: a single chromatic octave (C4–C5, 13 bars), evenly
    /// spaced with no black-key analog — reuses `makeLayout` with an empty
    /// `blacks` array, so each bar gets a full-height rect exactly like a
    /// piano white key. Real pitches (not GM-note-override zones like drums),
    /// since xylophone/glockenspiel/vibraphone/marimba/tubular-bells/handbells
    /// are all genuinely tuned instruments — only the timbre (InstrumentPreset)
    /// changes, via the existing instrument picker, not the layout.
    static let malletBarsLayout: [PaperPianoKey] = makeLayout(
        whites: [
            (.C,4),(.CSharp,4),(.D,4),(.DSharp,4),(.E,4),(.F,4),(.FSharp,4),
            (.G,4),(.GSharp,4),(.A,4),(.ASharp,4),(.B,4),(.C,5)
        ],
        blacks: [])

    /// Builds thin, gapped string zones (unlike `makeLayout`'s contiguous
    /// full-width bars) — each string is a narrow strip centered in its own
    /// even slot, with visible gaps between strings like a real zither/harp.
    /// Rendered via `ZoneBoardView` (drives position purely from
    /// `normalizedFrame`), not `VirtualPianoView` (which ignores
    /// `normalizedFrame` and always tiles keys edge-to-edge by index — wrong
    /// for anything with gaps).
    private static func makeStringLayout(pitches: [(NotePitch, Int)]) -> [PaperPianoKey] {
        let n = pitches.count
        let slot = 1.0 / Double(n)
        let stringWidth = slot * 0.4
        return pitches.enumerated().map { i, pitch in
            var k = PaperPianoKey(id: i, note: pitch.0, octave: pitch.1,
                                  isBlack: false, whiteKeyIndex: i, blackKeyOffset: 0)
            let x = slot * Double(i) + (slot - stringWidth) / 2.0
            k.normalizedFrame = CGRect(x: x, y: 0, width: stringWidth, height: 1.0)
            return k
        }
    }

    /// Zither: 2 diatonic octaves, C3–C5 (15 strings, no sharps/flats — real
    /// zithers/lap harps are typically diatonic, one string per scale degree).
    static let zitherLayout: [PaperPianoKey] = makeStringLayout(pitches: [
        (.C,3),(.D,3),(.E,3),(.F,3),(.G,3),(.A,3),(.B,3),
        (.C,4),(.D,4),(.E,4),(.F,4),(.G,4),(.A,4),(.B,4),(.C,5)
    ])

    /// Legacy alias: the 3-octave layout (existing call sites; prefer variant APIs).
    static var layout: [PaperPianoKey] { threeOctaveLayout }

    static func layout(for variant: KeyboardVariant) -> [PaperPianoKey] {
        switch variant {
        case .threeOctave: return threeOctaveLayout
        case .twoOctave:   return twoOctaveLayout
        case .drumKit:     return drumKitLayout
        case .malletBars:  return malletBarsLayout
        case .zither:      return zitherLayout
        }
    }

    private static let byIDThree = Dictionary(uniqueKeysWithValues: threeOctaveLayout.map { ($0.id, $0) })
    private static let byIDTwo = Dictionary(uniqueKeysWithValues: twoOctaveLayout.map { ($0.id, $0) })
    private static let byIDDrum = Dictionary(uniqueKeysWithValues: drumKitLayout.map { ($0.id, $0) })
    private static let byIDMallet = Dictionary(uniqueKeysWithValues: malletBarsLayout.map { ($0.id, $0) })
    private static let byIDZither = Dictionary(uniqueKeysWithValues: zitherLayout.map { ($0.id, $0) })

    static func byID(_ id: Int, variant: KeyboardVariant) -> PaperPianoKey? {
        switch variant {
        case .threeOctave: return byIDThree[id]
        case .twoOctave:   return byIDTwo[id]
        case .drumKit:     return byIDDrum[id]
        case .malletBars:  return byIDMallet[id]
        case .zither:      return byIDZither[id]
        }
    }
}

// MARK: - Interaction Model

/// How a zone responds to a fingertip. Piano/organ-style instruments sustain
/// for as long as the finger occupies the zone; struck/plucked instruments
/// (drums, mallets, zither) fire once on arrival and decay on their own —
/// tying note-off to the finger leaving would routinely clip their tails.
enum InteractionModel {
    case sustained
    case struckOnce
}

// MARK: - Keyboard Variant

/// Which printed sheet is in front of the camera. Encoded in the corner QR
/// payloads (`TAPNOTE:TL` = 3-octave legacy bare form, `TAPNOTE:3:TL` = same
/// explicitly, `TAPNOTE:2:TL` = 2-octave), so the paper identifies itself and
/// the app switches layouts automatically.
enum KeyboardVariant: String, CaseIterable {
    case threeOctave, twoOctave, drumKit, malletBars, zither

    var displayName: String {
        switch self {
        case .threeOctave: return "3 octaves"
        case .twoOctave:   return "2 octaves"
        case .drumKit:     return "Drum Kit"
        case .malletBars:  return "Mallet & Bells"
        case .zither:      return "Zither"
        }
    }

    var interactionModel: InteractionModel {
        switch self {
        case .threeOctave, .twoOctave:          return .sustained
        case .drumKit, .malletBars, .zither:    return .struckOnce
        }
    }

    /// MIDI channel notes go out on. Independent of `interactionModel` —
    /// mallets/zither are struck but still melodic, so they stay on channel
    /// 0; only percussion needs the GM percussion channel (9).
    var midiChannel: UInt8 {
        switch self {
        case .threeOctave, .twoOctave, .malletBars, .zither: return 0
        case .drumKit:                                       return 9
        }
    }

    /// Whether the on-screen keyboard should render via the generic
    /// `ZoneBoardView` (positions purely from `normalizedFrame`, so it
    /// handles gaps and non-row layouts) rather than `VirtualPianoView`
    /// (which ignores `normalizedFrame` and always tiles keys edge-to-edge
    /// by index — correct for piano/mallet's contiguous bars, wrong for
    /// drums' spatial pads or zither's thin gapped strings).
    var usesZoneBoard: Bool {
        switch self {
        case .threeOctave, .twoOctave, .malletBars: return false
        case .drumKit, .zither:                     return true
        }
    }

    /// The QR sub-prefix identifying this sheet (the part of the payload
    /// after "TAPNOTE:", before its own trailing ":"). `threeOctave`'s token
    /// is also reachable via the bare legacy form with no token at all —
    /// sheets printed before this scheme existed must keep working.
    var qrToken: String {
        switch self {
        case .threeOctave: return "3"
        case .twoOctave:   return "2"
        case .drumKit:     return "DRUM"
        case .malletBars:  return "MALLET"
        case .zither:      return "ZITHER"
        }
    }

    /// Token → variant, built once from `qrToken` so new sheets are additive
    /// data (a new case + token), not more `if`/`else` branches.
    private static let byToken: [String: KeyboardVariant] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.qrToken, $0) })

    /// Parses a QR payload's post-"TAPNOTE:" suffix into (variant, corner-name
    /// suffix), trying the longest known token first (so no future token can
    /// be misread as a prefix of another). No token match at all → the legacy
    /// bare-prefix default, `threeOctave`.
    static func parseToken(from suffix: String) -> (variant: KeyboardVariant, rest: String) {
        let tokensLongestFirst = byToken.keys.sorted { $0.count > $1.count }
        for token in tokensLongestFirst where suffix.hasPrefix(token + ":") {
            return (byToken[token]!, String(suffix.dropFirst(token.count + 1)))
        }
        return (.threeOctave, suffix)
    }
}

// MARK: - Calibration State

struct KeyboardCalibration {
    /// The four corners of the printed keyboard in the camera preview's coordinate
    /// space, in the PAPER's canonical order [TL, TR, BL, BR] as printed (not as
    /// they appear in the image — the keyboard may be at any rotation in frame).
    /// Writes go through `setCorners(_:)` so the homographies stay cached.
    private(set) var corners: [CGPoint] = []
    var isCalibrated: Bool { corners.count == 4 }

    /// Which printed sheet these corners belong to (drives key hit-testing).
    var variant: KeyboardVariant = .threeOctave

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
    /// keyboard rectangle.
    ///
    /// `corners` must be in the PAPER's canonical order [TL, TR, BL, BR] as
    /// printed — the QR payloads (TAPNOTE:TL…) and the guided manual-calibration
    /// prompts both guarantee it. The order is deliberately NOT inferred from
    /// image positions: the keyboard may appear at any rotation in frame (e.g.
    /// phone standing portrait at one end, viewing the keyboard lengthwise), so
    /// only the printed identity of each corner is meaningful.
    private static func cameraToKeyboardHomography(corners: [CGPoint]) -> [Double]? {
        guard corners.count == 4 else { return nil }
        return solveHomography(src: corners, dst: unitKeyboardCorners)
    }

    /// Inverse: unit keyboard rectangle → camera quad. Same order contract.
    private static func keyboardToCameraHomography(corners: [CGPoint]) -> [Double]? {
        guard corners.count == 4 else { return nil }
        return solveHomography(src: unitKeyboardCorners, dst: corners)
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

    /// Returns which zone (if any) a preview-space touch point lands on,
    /// against the active sheet variant's layout. Generic across instrument
    /// families: black-key-first ordering only matters for piano-shaped
    /// layouts (where they visually overlap); for a layout with no black
    /// zones the first loop simply matches nothing.
    func key(at previewPt: CGPoint, previewSize: CGSize) -> PaperPianoKey? {
        guard let norm = normalizedPoint(from: previewPt, previewSize: previewSize) else { return nil }
        let layout = PaperPianoKey.layout(for: variant)
        // Check black keys first (they sit on top)
        for key in layout where key.isBlack {
            if key.normalizedFrame.contains(norm) { return key }
        }
        for key in layout where !key.isBlack {
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
