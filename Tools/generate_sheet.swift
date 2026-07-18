#!/usr/bin/env swift
//
// generate_sheet.swift — generates print-ready, QR-cornered instrument sheets.
//
// Formalizes the ad-hoc PDF-generation approach used to build the piano sheets
// (mm-based zone rects via CGContext, QR corners via CIQRCodeGenerator) into a
// reusable, parametrized tool so future instrument sheets (drums, mallets,
// zither, …) don't each need a one-off script.
//
// Usage:
//   swift Tools/generate_sheet.swift <sheet-name> [output-directory]
//   swift Tools/generate_sheet.swift list
//
// Each SheetDefinition's zone rects are in millimeters on the page — keep
// them numerically in sync with the corresponding Swift layout in
// PaperPianoModel.swift (e.g. makeLayout/makeDrumLayout) so the printed paper
// and the app's hit-testing never drift apart.
//
// QR payloads are "TAPNOTE:<token>:<corner>" (corner ∈ TL,TR,BL,BR), matching
// KeyboardVariant.qrToken / KeyboardVariant.parseToken(from:) in
// Features/PaperPiano/PaperPianoModel.swift.

import AppKit
import CoreImage

// MARK: - Units

let mm: CGFloat = 72.0 / 25.4   // PDF points per millimeter

// MARK: - Sheet Definition

struct Zone {
    let label: String
    /// Rect in millimeters, relative to the sheet's own local origin (0,0 at
    /// its bottom-left) — NOT page-absolute; `SheetDefinition.origin` places it.
    let rect: CGRect
    var isAccent: Bool = false   // e.g. piano's "C" white keys, drum kick
    /// True for a zone whose corner sits near a printed QR marker — its
    /// label needs to be nudged clear of the QR's white backing. Only
    /// matters when the zone is short enough that the QR backing (~50mm)
    /// reaches into the default label position; piano keys are tall enough
    /// (150mm) to never need this, shorter zones (mallet bars) do.
    var isCornerAdjacent: Bool = false
}

struct SheetDefinition {
    let name: String
    let title: String
    let subtitle: String
    let qrToken: String          // e.g. "2", "3", "DRUM", "MALLET", "ZITHER"
    let pageSize: CGSize         // mm
    /// Where the zone group's local (0,0) sits on the page, in mm.
    let origin: CGPoint
    let zones: [Zone]
    let qrSizeMM: CGFloat
    /// The zone-group's own bounding size in mm (defines where the 4 corner
    /// QRs go, at `origin` and `origin + groupSize`).
    let groupSize: CGSize
}

// MARK: - QR

func qrImage(_ text: String) -> CGImage? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(text.data(using: .ascii), forKey: "inputMessage")
    // Correction M keeps short payloads in a coarser module grid (bigger
    // modules on paper) than the default H — verified to decode reliably at
    // typical camera distance; see CameraSessionManager's QR detection notes.
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage else { return nil }
    let scaled = out.transformed(by: CGAffineTransform(scaleX: 24, y: 24))
    return CIContext().createCGImage(scaled, from: scaled.extent)
}

// MARK: - PDF Drawing

func beginPage(_ ctx: CGContext, size: CGSize) {
    ctx.beginPDFPage(nil)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
}

func endPage(_ ctx: CGContext) {
    NSGraphicsContext.current = nil
    ctx.endPDFPage()
}

func drawTitle(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 15) {
    (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
        .font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.systemIndigo])
}

/// Draws one zone: a rounded rect + centered label.
func drawZone(_ ctx: CGContext, zone: Zone, origin: CGPoint) {
    let r = CGRect(x: (origin.x + zone.rect.minX) * mm,
                   y: (origin.y + zone.rect.minY) * mm,
                   width: zone.rect.width * mm, height: zone.rect.height * mm)
    let path = NSBezierPath(roundedRect: r, xRadius: 3 * mm, yRadius: 3 * mm)
    (zone.isAccent ? NSColor(calibratedWhite: 0.93, alpha: 1) : NSColor.white).setFill()
    path.fill()
    NSColor(calibratedWhite: 0.1, alpha: 1).setStroke()
    path.lineWidth = 1.6
    path.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: min(16, r.height * 0.18)),
        .foregroundColor: zone.isAccent ? NSColor.systemIndigo : NSColor(calibratedWhite: 0.35, alpha: 1)]
    let s = zone.label as NSString
    let sz = s.size(withAttributes: attrs)
    // Corner-adjacent zones (e.g. the first/last bar of a short row) can have
    // a QR's white backing overlapping the default near-bottom label spot —
    // center the label vertically instead, clear of both the near and far
    // corner's backing.
    let labelY = zone.isCornerAdjacent
        ? r.midY - sz.height / 2
        : r.minY + r.height * 0.12
    s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: labelY), withAttributes: attrs)
}

/// Draws the 4 corner QR markers around a zone group's bounding box.
func drawCornerQRs(_ ctx: CGContext, groupOrigin: CGPoint, groupSize: CGSize,
                   qrToken: String, qrSizeMM: CGFloat) {
    let corners: [(String, CGPoint)] = [
        ("TL", CGPoint(x: groupOrigin.x, y: groupOrigin.y + groupSize.height)),
        ("TR", CGPoint(x: groupOrigin.x + groupSize.width, y: groupOrigin.y + groupSize.height)),
        ("BL", CGPoint(x: groupOrigin.x, y: groupOrigin.y)),
        ("BR", CGPoint(x: groupOrigin.x + groupSize.width, y: groupOrigin.y)),
    ]
    let qrSize = qrSizeMM * mm
    for (corner, ptMM) in corners {
        let center = CGPoint(x: ptMM.x * mm, y: ptMM.y * mm)
        let r = CGRect(x: center.x - qrSize / 2, y: center.y - qrSize / 2, width: qrSize, height: qrSize)
        NSColor.white.setFill()
        NSBezierPath(rect: r.insetBy(dx: -4 * mm, dy: -4 * mm)).fill()
        if let qr = qrImage("TAPNOTE:\(qrToken):\(corner)") {
            ctx.interpolationQuality = .none
            ctx.draw(qr, in: r)
        }
    }
}

/// Renders a full `SheetDefinition` to a single-page PDF at `outputURL`.
func renderSheet(_ def: SheetDefinition, to outputURL: URL) {
    var box = CGRect(x: 0, y: 0, width: def.pageSize.width * mm, height: def.pageSize.height * mm)
    guard let ctx = CGContext(outputURL as CFURL, mediaBox: &box, nil) else {
        fatalError("could not create PDF context for \(outputURL.path)")
    }
    beginPage(ctx, size: box.size)

    for zone in def.zones { drawZone(ctx, zone: zone, origin: def.origin) }
    drawCornerQRs(ctx, groupOrigin: def.origin, groupSize: def.groupSize,
                 qrToken: def.qrToken, qrSizeMM: def.qrSizeMM)

    drawTitle(ctx, def.title, x: def.origin.x * mm,
             y: (def.origin.y + def.groupSize.height) * mm + 22 * mm, size: 20)
    drawTitle(ctx, def.subtitle, x: def.origin.x * mm, y: 12 * mm, size: 11)

    endPage(ctx)
    ctx.closePDF()
    print("wrote \(outputURL.path)")
}

// MARK: - Sheet Definitions

/// Piano key proportions (real key size): 23.5mm wide white keys, 150mm long,
/// black keys 60% width / 62% length — matches PaperPianoKey.makeLayout.
func pianoZones(whiteLabels: [String], blackLabels: [(String, Int)], accentPrefix: String) -> (zones: [Zone], width: CGFloat, height: CGFloat) {
    let ww: CGFloat = 23.5, wl: CGFloat = 150.0
    let bw = ww * 0.6, bl = wl * 0.62
    var zones: [Zone] = []
    for (i, label) in whiteLabels.enumerated() {
        let r = CGRect(x: CGFloat(i) * ww, y: 0, width: ww, height: wl)
        zones.append(Zone(label: label, rect: r, isAccent: label.hasPrefix(accentPrefix) && !label.contains("#")))
    }
    for (label, leftIdx) in blackLabels {
        let cx = CGFloat(leftIdx + 1) * ww
        let r = CGRect(x: cx - bw / 2, y: wl - bl, width: bw, height: bl)
        zones.append(Zone(label: label, rect: r))
    }
    return (zones, CGFloat(whiteLabels.count) * ww, wl)
}

let twoOctavePiano: SheetDefinition = {
    let whites = ["C3","D3","E3","F3","G3","A3","B3","C4","D4","E4","F4","G4","A4","B4","C5"]
    let blacks: [(String, Int)] = [("C#3",0),("D#3",1),("F#3",3),("G#3",4),("A#3",5),
                                    ("C#4",7),("D#4",8),("F#4",10),("G#4",11),("A#4",12)]
    let (zones, w, h) = pianoZones(whiteLabels: whites, blackLabels: blacks, accentPrefix: "C")
    let margin: CGFloat = 40
    return SheetDefinition(
        name: "2oct", title: "TapNote · 2-Octave Paper Piano (C3–C5) · TRUE KEY SIZE",
        subtitle: "Print on A3 at 100% scale. Keys are real piano size — lay flat, keep all 4 QR squares visible.",
        qrToken: "2", pageSize: CGSize(width: 420, height: 297),
        origin: CGPoint(x: (420 - w) / 2, y: margin), zones: zones,
        qrSizeMM: 42, groupSize: CGSize(width: w, height: h))
}()

let threeOctavePianoNote = "3-octave piano is printed across 2 tiled A3 pages — " +
    "regenerating it requires the two-page tiling logic (see git history, commit 9f422b7); " +
    "not reproduced here since Phase 0 only needed the tool to exist, not to reprint " +
    "already-correct, already-printed sheets."

/// 5-pad starter drum kit. Zone fractions here MUST match
/// PaperPianoKey.drumKitLayout in Features/PaperPiano/PaperPianoModel.swift —
/// keep the two in sync by hand (both are small/rare-to-change enough that a
/// shared data file wasn't worth the indirection yet).
let drumKit: SheetDefinition = {
    let groupW: CGFloat = 340, groupH: CGFloat = 220   // mm — bigger than piano keys; hand-sized pads
    // (label, normalized rect — same fractions as PaperPianoKey.drumKitLayout)
    let pads: [(String, CGRect)] = [
        ("Kick",      CGRect(x: 0.28, y: 0.03, width: 0.34, height: 0.28)),
        ("Hi-Hat",    CGRect(x: 0.08, y: 0.35, width: 0.28, height: 0.28)),
        ("Snare",     CGRect(x: 0.42, y: 0.35, width: 0.28, height: 0.28)),
        ("Crash",     CGRect(x: 0.03, y: 0.68, width: 0.30, height: 0.29)),
        ("Floor Tom", CGRect(x: 0.67, y: 0.68, width: 0.30, height: 0.29)),
    ]
    let zones = pads.map { label, norm in
        Zone(label: label,
            rect: CGRect(x: norm.minX * groupW, y: norm.minY * groupH,
                        width: norm.width * groupW, height: norm.height * groupH),
            isAccent: label == "Kick")
    }
    let margin: CGFloat = 40
    return SheetDefinition(
        name: "drumkit", title: "TapNote · 5-Pad Starter Drum Kit",
        subtitle: "Print on A3 at 100% scale. Lay flat, keep all 4 QR squares visible — tap a pad to play it.",
        qrToken: "DRUM", pageSize: CGSize(width: 420, height: 297),
        origin: CGPoint(x: (420 - groupW) / 2, y: margin), zones: zones,
        qrSizeMM: 42, groupSize: CGSize(width: groupW, height: groupH))
}()

/// Mallet/bell family: one chromatic octave, C4–C5, evenly-spaced bars with
/// no black-key analog. Same 13 pitches as PaperPianoKey.malletBarsLayout —
/// keep the two in sync by hand. Timbre (xylophone/glockenspiel/vibraphone/
/// marimba/tubular bells/handbells) is chosen in-app via the instrument
/// picker, not baked into the sheet.
let malletBars: SheetDefinition = {
    let labels = ["C4","C#4","D4","D#4","E4","F4","F#4","G4","G#4","A4","A#4","B4","C5"]
    let ww: CGFloat = 23.5, wl: CGFloat = 90.0   // shorter bars than piano keys
    var zones: [Zone] = []
    for (i, label) in labels.enumerated() {
        let r = CGRect(x: CGFloat(i) * ww, y: 0, width: ww, height: wl)
        let isEnd = i == 0 || i == labels.count - 1
        zones.append(Zone(label: label, rect: r, isAccent: label == "C4" || label == "C5",
                          isCornerAdjacent: isEnd))
    }
    let w = CGFloat(labels.count) * ww
    let margin: CGFloat = 40
    return SheetDefinition(
        name: "mallet", title: "TapNote · Mallet & Bells (1 Octave, C4–C5)",
        subtitle: "Print on A3 at 100% scale. Pick a timbre in-app: Xylophone, Glockenspiel, Vibraphone, Marimba, Tubular Bells, or Handbells.",
        qrToken: "MALLET", pageSize: CGSize(width: 420, height: 297),
        origin: CGPoint(x: (420 - w) / 2, y: margin), zones: zones,
        qrSizeMM: 42, groupSize: CGSize(width: w, height: wl))
}()

// MARK: - Registry

let registry: [String: SheetDefinition] = [
    "2oct": twoOctavePiano,
    "drumkit": drumKit,
    "mallet": malletBars,
]

// MARK: - CLI

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: swift Tools/generate_sheet.swift <sheet-name> [output-dir]")
    print("       swift Tools/generate_sheet.swift list")
    exit(1)
}

if args[1] == "list" {
    print("Available sheets: \(registry.keys.sorted().joined(separator: ", "))")
    print("Note: \(threeOctavePianoNote)")
    exit(0)
}

guard let def = registry[args[1]] else {
    print("Unknown sheet '\(args[1])'. Available: \(registry.keys.sorted().joined(separator: ", "))")
    exit(1)
}

let outDir = args.count >= 3 ? args[2] : FileManager.default.currentDirectoryPath
let outURL = URL(fileURLWithPath: outDir).appendingPathComponent("TapNote_\(def.name)_generated.pdf")
renderSheet(def, to: outURL)
