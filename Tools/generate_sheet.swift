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

/// How a zone is rendered. Purely cosmetic — the zone's `rect` is always the
/// literal hit-test area regardless of style, so richer graphics never change
/// where a tap registers (keeps the sheet in sync with PaperPianoModel).
enum ZoneStyle { case plain, drumhead, cymbal, malletBar, bassCell }

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
    /// Cosmetic rendering style (default keeps the plain rounded-rect key look).
    var style: ZoneStyle = .plain
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

/// Draws one zone, dispatching on its cosmetic style. `rect` is always the
/// zone's literal hit-test box; every renderer draws *within* it.
func drawZone(_ ctx: CGContext, zone: Zone, origin: CGPoint) {
    let r = CGRect(x: (origin.x + zone.rect.minX) * mm,
                   y: (origin.y + zone.rect.minY) * mm,
                   width: zone.rect.width * mm, height: zone.rect.height * mm)
    switch zone.style {
    case .plain:     drawPlainZone(zone, in: r)
    case .drumhead:  drawDrumhead(zone, in: r)
    case .cymbal:    drawCymbal(zone, in: r)
    case .malletBar: drawMalletBar(zone, in: r)
    case .bassCell:  drawBassCell(zone, in: r)
    }
}

/// A bass fret cell: just the note name — the neck backdrop (strings, frets,
/// inlays) supplies all the structure. `isAccent` marks open-string cells,
/// which sit on the light headstock strip and need dark text.
func drawBassCell(_ zone: Zone, in r: CGRect) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 8),
        .foregroundColor: zone.isAccent ? NSColor(calibratedWhite: 0.25, alpha: 1)
                                        : NSColor(calibratedWhite: 0.95, alpha: 1)]
    let s = zone.label as NSString
    let sz = s.size(withAttributes: attrs)
    s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.minY + 1.5 * mm), withAttributes: attrs)
}

/// The bass neck backdrop: headstock strip (open column), wood fingerboard,
/// nut, fret wires, inlay dots at frets 3/5/7, four strings of decreasing
/// gauge (low E thickest, at the bottom like tablature), string names at the
/// left and fret numbers along the top. All geometry mirrors
/// `PaperPianoKey.bassLayout` (26mm vertical inset, 4×32mm rows, 9×38mm cols).
func drawBassNeck(_ def: SheetDefinition) {
    let o = def.origin
    let colW: CGFloat = 38, insetY: CGFloat = 26, neckH: CGFloat = 128
    let neckTop = insetY + neckH

    // Headstock strip: the open-string column, left of the nut.
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: o.x * mm, y: (o.y + insetY) * mm,
                                     width: colW * mm, height: neckH * mm),
                 xRadius: 2 * mm, yRadius: 2 * mm).fill()

    // Fingerboard: rosewood tone from the nut to the last fret.
    NSColor(calibratedRed: 0.36, green: 0.24, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: (o.x + colW) * mm, y: (o.y + insetY) * mm,
                                     width: (def.groupSize.width - colW) * mm, height: neckH * mm),
                 xRadius: 2 * mm, yRadius: 2 * mm).fill()

    // Inlay dots at frets 3, 5, 7 (cell centers, mid-neck).
    NSColor(calibratedRed: 0.94, green: 0.90, blue: 0.80, alpha: 1).setFill()
    for f in [3, 5, 7] {
        let cx = o.x + (CGFloat(f) + 0.5) * colW
        let cy = o.y + insetY + neckH / 2
        NSBezierPath(ovalIn: CGRect(x: (cx - 4) * mm, y: (cy - 4) * mm,
                                    width: 8 * mm, height: 8 * mm)).fill()
    }

    // Nut (thick, at the fret-0/1 boundary), then the fret wires.
    NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: (o.x + colW - 1.2) * mm, y: (o.y + insetY) * mm,
                              width: 2.4 * mm, height: neckH * mm)).fill()
    NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
    for c in 2...8 {
        NSBezierPath(rect: CGRect(x: (o.x + CGFloat(c) * colW - 0.5) * mm, y: (o.y + insetY) * mm,
                                  width: 1.0 * mm, height: neckH * mm)).fill()
    }

    // Strings: E (bottom) thickest → G thinnest, full width incl. open column.
    let gauges: [CGFloat] = [2.4, 1.9, 1.4, 1.0]
    let names = ["E", "A", "D", "G"]
    for (row, gauge) in gauges.enumerated() {
        let cy = o.y + insetY + 32 * CGFloat(row) + 16
        NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: o.x * mm, y: (cy - gauge / 2) * mm,
                                  width: def.groupSize.width * mm, height: gauge * mm)).fill()
        // String name at the left of its row.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.systemIndigo]
        (names[row] as NSString).draw(
            at: CGPoint(x: (o.x - 9) * mm, y: (cy - 2.5) * mm), withAttributes: attrs)
    }

    // Fret numbers along the top edge of the neck. Only 1–7: the 0 and 8
    // positions sit under the corner QRs' white backing (the open column
    // identifies itself via its note labels anyway).
    for f in 1...7 {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)]
        let s = "\(f)" as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: (o.x + (CGFloat(f) + 0.5) * colW) * mm - sz.width / 2,
                           y: (o.y + neckTop + 3) * mm), withAttributes: attrs)
    }
}

/// Shared label placement. `centered` overrides the default near-bottom spot
/// (used by round pads so the text sits in the middle of the head).
func drawZoneLabel(_ zone: Zone, in r: CGRect, color: NSColor,
                   centered: Bool = false, sizeCap: CGFloat = 16) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: min(sizeCap, max(9, r.height * 0.16))),
        .foregroundColor: color]
    let s = zone.label as NSString
    let sz = s.size(withAttributes: attrs)
    let labelY: CGFloat
    if centered || zone.isCornerAdjacent { labelY = r.midY - sz.height / 2 }
    else { labelY = r.minY + r.height * 0.12 }
    s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: labelY), withAttributes: attrs)
}

/// The original flat rounded-rect key (piano, zither) — unchanged look.
func drawPlainZone(_ zone: Zone, in r: CGRect) {
    let path = NSBezierPath(roundedRect: r, xRadius: 3 * mm, yRadius: 3 * mm)
    (zone.isAccent ? NSColor(calibratedWhite: 0.93, alpha: 1) : NSColor.white).setFill()
    path.fill()
    NSColor(calibratedWhite: 0.1, alpha: 1).setStroke()
    path.lineWidth = 1.6
    path.stroke()
    drawZoneLabel(zone, in: r,
        color: zone.isAccent ? .systemIndigo : NSColor(calibratedWhite: 0.35, alpha: 1))
}

/// A membrane drum (kick/snare/floor tom): pale head, dark shell rim, chrome
/// tension lugs around it. Kick is accented in indigo.
func drawDrumhead(_ zone: Zone, in rect: CGRect) {
    let d = min(rect.width, rect.height) * 0.90
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let head = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    let rimColor = zone.isAccent ? NSColor.systemIndigo : NSColor(calibratedWhite: 0.15, alpha: 1)

    NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
    NSBezierPath(ovalIn: head).fill()

    // Inner resonance ring.
    let inner = head.insetBy(dx: d * 0.13, dy: d * 0.13)
    NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
    let ip = NSBezierPath(ovalIn: inner); ip.lineWidth = 1.0; ip.stroke()

    // Tension lugs sitting on the counterhoop.
    let lugCount = 8, lugR = d * 0.03, ringR = d / 2
    for i in 0..<lugCount {
        let a = CGFloat(i) / CGFloat(lugCount) * 2 * .pi + .pi / CGFloat(lugCount)
        let lc = CGPoint(x: c.x + cos(a) * ringR, y: c.y + sin(a) * ringR)
        let lr = CGRect(x: lc.x - lugR, y: lc.y - lugR, width: lugR * 2, height: lugR * 2)
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: lr).fill()
        let p = NSBezierPath(ovalIn: lr); p.lineWidth = 0.6
        NSColor(calibratedWhite: 0.3, alpha: 1).setStroke(); p.stroke()
    }

    // Shell rim on top of the lug bases.
    let rim = NSBezierPath(ovalIn: head); rim.lineWidth = 3.4
    rimColor.setStroke(); rim.stroke()

    drawZoneLabel(zone, in: rect, color: rimColor, centered: true)
}

/// A brass cymbal (hi-hat/crash): gold disc, concentric tone grooves, a raised
/// bell and center hole. Label sits low so it stays legible on the brass.
func drawCymbal(_ zone: Zone, in rect: CGRect) {
    let d = min(rect.width, rect.height) * 0.94
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let disc = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)

    NSColor(calibratedRed: 0.82, green: 0.66, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: disc).fill()

    NSColor(calibratedRed: 0.60, green: 0.46, blue: 0.16, alpha: 0.9).setStroke()
    for f in [0.82, 0.62, 0.42] {
        let gr = disc.insetBy(dx: d * (1 - f) / 2, dy: d * (1 - f) / 2)
        let p = NSBezierPath(ovalIn: gr); p.lineWidth = 0.8; p.stroke()
    }

    // Raised bell + mounting hole.
    let bell = disc.insetBy(dx: d * 0.42, dy: d * 0.42)
    NSColor(calibratedRed: 0.90, green: 0.74, blue: 0.38, alpha: 1).setFill()
    NSBezierPath(ovalIn: bell).fill()
    let hole = CGRect(x: c.x - d * 0.02, y: c.y - d * 0.02, width: d * 0.04, height: d * 0.04)
    NSColor(calibratedWhite: 0.25, alpha: 1).setFill(); NSBezierPath(ovalIn: hole).fill()

    let edge = NSBezierPath(ovalIn: disc); edge.lineWidth = 1.6
    NSColor(calibratedRed: 0.50, green: 0.40, blue: 0.15, alpha: 1).setStroke(); edge.stroke()

    drawZoneLabel(zone, in: rect, color: NSColor(calibratedWhite: 0.12, alpha: 1))
}

/// A tuned wooden bar (xylophone/marimba look; also stands in for metal timbres
/// chosen in-app). Wood-toned, rounded ends, dark cord holes at the nodal
/// points that line up with the printed frame rails. Sharps are darker.
func drawMalletBar(_ zone: Zone, in rect: CGRect) {
    let isSharp = zone.label.contains("#")
    let base = isSharp ? NSColor(calibratedRed: 0.55, green: 0.37, blue: 0.20, alpha: 1)
                       : NSColor(calibratedRed: 0.86, green: 0.63, blue: 0.38, alpha: 1)
    let radius = rect.width * 0.32
    let bar = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    if let grad = NSGradient(starting: base.blended(withFraction: 0.20, of: .white) ?? base,
                             ending: base.blended(withFraction: 0.18, of: .black) ?? base) {
        grad.draw(in: bar, angle: 90)
    } else { base.setFill(); bar.fill() }
    bar.lineWidth = 1.0
    NSColor(calibratedWhite: 0.15, alpha: 0.55).setStroke(); bar.stroke()

    // Cord holes at ~20% / ~80% up — the nodal points a real bar is strung at.
    for fy in [0.2, 0.8] {
        let hy = rect.minY + rect.height * CGFloat(fy)
        let hr = rect.width * 0.13
        let h = CGRect(x: rect.midX - hr, y: hy - hr, width: hr * 2, height: hr * 2)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(ovalIn: h).fill()
    }

    drawZoneLabel(zone, in: rect,
        color: isSharp ? .white : NSColor(calibratedWhite: 0.12, alpha: 1))
}

/// The two frame rails a mallet instrument's bars are strung on — drawn behind
/// the bars so they show through the gaps and under each bar's cord holes.
func drawMalletRails(_ def: SheetDefinition) {
    for fy in [0.2, 0.8] {
        let y = (def.origin.y + def.groupSize.height * CGFloat(fy)) * mm
        let rail = CGRect(x: (def.origin.x - 5) * mm, y: y - 1.4 * mm,
                          width: (def.groupSize.width + 10) * mm, height: 2.8 * mm)
        NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 1.4 * mm, yRadius: 1.4 * mm).fill()
    }
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

    // Backdrops: mallet frame rails / bass neck sit behind their zones.
    if def.zones.contains(where: { if case .malletBar = $0.style { return true }; return false }) {
        drawMalletRails(def)
    }
    if def.zones.contains(where: { if case .bassCell = $0.style { return true }; return false }) {
        drawBassNeck(def)
    }
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
            isAccent: label == "Kick",
            style: (label == "Hi-Hat" || label == "Crash") ? .cymbal : .drumhead)
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
                          isCornerAdjacent: isEnd, style: .malletBar))
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

/// Zither: 2 diatonic octaves (C3–C5, 15 strings), thin gapped strips rather
/// than contiguous bars — same 40%-of-slot string width as
/// PaperPianoKey.makeStringLayout, kept in sync by hand.
let zither: SheetDefinition = {
    let labels = ["C3","D3","E3","F3","G3","A3","B3",
                  "C4","D4","E4","F4","G4","A4","B4","C5"]
    let n = labels.count
    let slot: CGFloat = 24.0, stringW = slot * 0.4, stringL: CGFloat = 180.0
    var zones: [Zone] = []
    for (i, label) in labels.enumerated() {
        let x = CGFloat(i) * slot + (slot - stringW) / 2
        let r = CGRect(x: x, y: 0, width: stringW, height: stringL)
        let isEnd = i == 0 || i == n - 1
        zones.append(Zone(label: label, rect: r,
                          isAccent: label.hasPrefix("C") && label.count == 2,
                          isCornerAdjacent: isEnd))
    }
    let w = CGFloat(n) * slot
    let margin: CGFloat = 40
    return SheetDefinition(
        name: "zither", title: "TapNote · Zither (2 Octaves, C3–C5)",
        subtitle: "Print on A3 at 100% scale. Pluck a string — lay flat, keep all 4 QR squares visible.",
        qrToken: "ZITHER", pageSize: CGSize(width: 420, height: 297),
        origin: CGPoint(x: (420 - w) / 2, y: margin), zones: zones,
        qrSizeMM: 42, groupSize: CGSize(width: w, height: stringL))
}()

/// Bass guitar: 4 strings (E1 A1 D2 G2, low E at the bottom like tablature) ×
/// fret positions 0–8 (0 = open, left of the nut). Pitch = open string + fret.
/// Cell geometry MUST match PaperPianoKey.bassLayout (26mm vertical inset for
/// QR clearance, 4×32mm string rows, 9×38mm fret columns) — kept in sync by
/// hand, like the drum kit.
let bassGuitar: SheetDefinition = {
    let openMidi = [28, 33, 38, 43]   // E1 A1 D2 G2, bottom row first
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let colW: CGFloat = 38, rowH: CGFloat = 32, insetY: CGFloat = 26
    let groupW = colW * 9, groupH: CGFloat = 180

    var zones: [Zone] = []
    for (row, open) in openMidi.enumerated() {
        for fret in 0..<9 {
            let midi = open + fret
            let r = CGRect(x: CGFloat(fret) * colW,
                           y: insetY + CGFloat(row) * rowH + 2.2,
                           width: colW, height: rowH - 4.4)
            zones.append(Zone(label: "\(names[midi % 12])\(midi / 12 - 1)",
                              rect: r, isAccent: fret == 0, style: .bassCell))
        }
    }
    return SheetDefinition(
        name: "bass", title: "TapNote · Bass Guitar (4 Strings × Frets 0–8, E1–D#3)",
        subtitle: "Print on A3 at 100% scale. Tap a string at a fret to pluck that note — the left column is the open string. Pick a bass in-app: Upright, Fingered, Picked, Fretless, Slap, or Synth.",
        qrToken: "BASS", pageSize: CGSize(width: 420, height: 297),
        origin: CGPoint(x: (420 - groupW) / 2, y: (297 - groupH) / 2 - 10), zones: zones,
        qrSizeMM: 42, groupSize: CGSize(width: groupW, height: groupH))
}()

// MARK: - QR Upgrade Patch

/// Upgrade patch for legacy prints: the app no longer recognizes pre-token QR
/// payloads (`TAPNOTE:<corner>`), so the original 3-octave sheets go invisible
/// to the scanner. Rather than reprinting the whole 2×A3 sheet, this renders
/// the 4 modern-format corner QRs (`TAPNOTE:3:<corner>`) as labeled cut-out
/// squares: print at 100%, cut along the dashed lines, and tape each square
/// over the matching corner QR of the old sheet, centering the new QR on the
/// old one (the QR's CENTER is the calibration corner, so centering preserves
/// the sheet's existing geometry exactly).
func renderQRPatch(token: String, title: String, to outputURL: URL) {
    let page = CGSize(width: 297, height: 210)   // A4 landscape, mm
    var box = CGRect(x: 0, y: 0, width: page.width * mm, height: page.height * mm)
    guard let ctx = CGContext(outputURL as CFURL, mediaBox: &box, nil) else {
        fatalError("could not create PDF context for \(outputURL.path)")
    }
    beginPage(ctx, size: box.size)

    drawTitle(ctx, title, x: 16 * mm, y: 190 * mm, size: 16)
    drawTitle(ctx, "Print at 100% scale. Cut out the 4 squares and tape each over the same-named corner QR of the old sheet, new QR centered on the old one.",
              x: 16 * mm, y: 181 * mm, size: 10)

    let qrSizeMM: CGFloat = 42          // matches the printed sheets' QR size
    let cell: CGFloat = 58              // cut square — fully covers the old QR + its white backing
    let gap: CGFloat = 8
    let rowX = (page.width - (4 * cell + 3 * gap)) / 2
    let rowY: CGFloat = 60

    for (i, corner) in ["TL", "TR", "BL", "BR"].enumerated() {
        let ox = rowX + CGFloat(i) * (cell + gap)
        let cellRect = CGRect(x: ox * mm, y: rowY * mm, width: cell * mm, height: cell * mm)

        // Dashed cut border.
        let border = NSBezierPath(rect: cellRect)
        border.setLineDash([3 * mm, 2 * mm], count: 2, phase: 0)
        border.lineWidth = 0.8
        NSColor(calibratedWhite: 0.45, alpha: 1).setStroke()
        border.stroke()

        // The QR, centered in the cell.
        let qrRect = CGRect(x: cellRect.midX - qrSizeMM * mm / 2,
                            y: cellRect.midY - qrSizeMM * mm / 2,
                            width: qrSizeMM * mm, height: qrSizeMM * mm)
        if let qr = qrImage("TAPNOTE:\(token):\(corner)") {
            ctx.interpolationQuality = .none
            ctx.draw(qr, in: qrRect)
        }

        // Corner label under the cell (outside the cut area).
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.systemIndigo]
        let s = corner as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: cellRect.midX - sz.width / 2, y: cellRect.minY - 7 * mm),
               withAttributes: attrs)
    }

    endPage(ctx)
    ctx.closePDF()
    print("wrote \(outputURL.path)")
}

// MARK: - Registry

let registry: [String: SheetDefinition] = [
    "2oct": twoOctavePiano,
    "drumkit": drumKit,
    "mallet": malletBars,
    "zither": zither,
    "bass": bassGuitar,
]

// MARK: - CLI

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: swift Tools/generate_sheet.swift <sheet-name> [output-dir]")
    print("       swift Tools/generate_sheet.swift list")
    exit(1)
}

if args[1] == "list" {
    print("Available sheets: \(registry.keys.sorted().joined(separator: ", ")), 3oct-qr-patch")
    print("Note: \(threeOctavePianoNote)")
    exit(0)
}

if args[1] == "3oct-qr-patch" {
    let outDir = args.count >= 3 ? args[2] : FileManager.default.currentDirectoryPath
    let outURL = URL(fileURLWithPath: outDir).appendingPathComponent("TapNote_3oct_QR_Patch.pdf")
    renderQRPatch(token: "3", title: "TapNote · QR Upgrade Patch — 3-Octave Piano",
                  to: outURL)
    exit(0)
}

guard let def = registry[args[1]] else {
    print("Unknown sheet '\(args[1])'. Available: \(registry.keys.sorted().joined(separator: ", "))")
    exit(1)
}

let outDir = args.count >= 3 ? args[2] : FileManager.default.currentDirectoryPath
let outURL = URL(fileURLWithPath: outDir).appendingPathComponent("TapNote_\(def.name)_generated.pdf")
renderSheet(def, to: outURL)
