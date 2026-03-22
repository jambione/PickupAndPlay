import SwiftUI

// MARK: - Sheet Music View

struct SheetMusicView: View {
    let exercise: Exercise
    let currentNoteIndex: Int
    let feedback: LessonSessionViewModel.NoteFeedback

    var body: some View {
        Canvas { context, size in
            drawStaff(context: context, size: size)
            drawClef(context: context, size: size)
            drawTimeSignature(context: context, size: size)
            drawNotes(context: context, size: size)
        }
        .background(Color(.systemBackground))
        .cornerRadius(Radius.md)
        .shadow(color: .black.opacity(0.05), radius: 6)
    }

    // MARK: - Layout Constants

    private var staffTop: CGFloat { 40 }
    private var staffLineSpacing: CGFloat { 12 }
    private var staffHeight: CGFloat { staffLineSpacing * 4 }
    private var noteStartX: CGFloat { 110 }
    private var noteSpacing: CGFloat { 52 }
    private var clefWidth: CGFloat { 40 }
    private var staffLeft: CGFloat { 16 }
    private var staffRight: CGFloat { 16 }

    /// Y position for a given note pitch in treble clef (middle line = B4)
    /// Staff lines from bottom (line 0) = E4, 1=G4, 2=B4, 3=D5, 4=F5
    private func yPosition(for pitch: NotePitch, octave: Int, size: CGSize) -> CGFloat {
        let middleLineY = staffTop + staffLineSpacing * 2

        // Treble clef: B4 sits on middle (3rd) line
        // Step units from B4 (each step = half staffLineSpacing)
        let stepHeight = staffLineSpacing / 2.0

        let semitoneFromB4 = semitoneDiff(pitch: pitch, octave: octave, refPitch: .B, refOctave: 4)
        let stepsFromB4 = semitonesToDiatonicSteps(semitones: semitoneFromB4, pitch: pitch, octave: octave)

        return middleLineY - CGFloat(stepsFromB4) * stepHeight
    }

    private func semitoneDiff(pitch: NotePitch, octave: Int, refPitch: NotePitch, refOctave: Int) -> Int {
        let a = (octave * 12) + (pitch.semitoneOffset + 9)
        let b = (refOctave * 12) + (refPitch.semitoneOffset + 9)
        return a - b
    }

    private func semitonesToDiatonicSteps(semitones: Int, pitch: NotePitch, octave: Int) -> Int {
        // Approximate: use the note's letter position
        let diatonicOrder: [NotePitch] = [.C, .D, .E, .F, .G, .A, .B]
        let refOrder: [NotePitch] = [.C, .D, .E, .F, .G, .A, .B]

        let pitchLetter = nearestNatural(pitch)
        let pitchIndex = diatonicOrder.firstIndex(of: pitchLetter) ?? 0
        let refIndex = refOrder.firstIndex(of: .B) ?? 6

        let octaveDiff = octave - 4
        let rawSteps = (pitchIndex - refIndex) + (octaveDiff * 7)
        return rawSteps
    }

    private func nearestNatural(_ pitch: NotePitch) -> NotePitch {
        switch pitch {
        case .CSharp: return .C
        case .DSharp: return .D
        case .FSharp: return .F
        case .GSharp: return .G
        case .ASharp: return .A
        default: return pitch
        }
    }

    // MARK: - Drawing

    private func drawStaff(context: GraphicsContext, size: CGSize) {
        var context = context
        let lineColor = Color.gray.opacity(0.5)

        for i in 0...4 {
            let y = staffTop + CGFloat(i) * staffLineSpacing
            var path = Path()
            path.move(to: CGPoint(x: staffLeft, y: y))
            path.addLine(to: CGPoint(x: size.width - staffRight, y: y))
            context.stroke(path, with: .color(lineColor), lineWidth: 1)
        }
    }

    private func drawClef(context: GraphicsContext, size: CGSize) {
        var context = context
        // Simple stylized G clef using text
        context.draw(
            Text("𝄞")
                .font(.system(size: 52))
                .foregroundColor(.primary),
            at: CGPoint(x: staffLeft + 18, y: staffTop + staffHeight / 2 - 4)
        )
    }

    private func drawTimeSignature(context: GraphicsContext, size: CGSize) {
        var context = context
        let parts = exercise.timeSignature.rawValue.split(separator: "/")
        guard parts.count == 2 else { return }

        let x: CGFloat = staffLeft + 48

        context.draw(
            Text(String(parts[0]))
                .font(.system(size: 16, weight: .bold, design: .default))
                .foregroundColor(.primary),
            at: CGPoint(x: x, y: staffTop + staffLineSpacing * 0.9)
        )
        context.draw(
            Text(String(parts[1]))
                .font(.system(size: 16, weight: .bold, design: .default))
                .foregroundColor(.primary),
            at: CGPoint(x: x, y: staffTop + staffLineSpacing * 2.9)
        )
    }

    private func drawNotes(context: GraphicsContext, size: CGSize) {
        var context = context

        for (i, note) in exercise.notes.enumerated() {
            let x = noteStartX + CGFloat(i) * noteSpacing
            let y = yPosition(for: note.pitch, octave: note.octave, size: size)

            let isCurrent = i == currentNoteIndex
            let isPast = i < currentNoteIndex

            // Note color
            let noteColor: Color = {
                if isCurrent {
                    switch feedback {
                    case .correct: return .green
                    case .incorrect: return .red
                    default: return .indigo
                    }
                }
                if isPast { return .gray.opacity(0.4) }
                return .primary
            }()

            // Draw note head
            let noteRadius: CGFloat = note.duration == .whole ? 7 : 6
            let noteRect = CGRect(x: x - noteRadius, y: y - noteRadius * 0.7,
                                  width: noteRadius * 2, height: noteRadius * 1.4)
            var notePath = Path(ellipseIn: noteRect)

            if note.duration == .whole {
                context.stroke(notePath, with: .color(noteColor), lineWidth: 2)
            } else {
                context.fill(notePath, with: .color(noteColor))
            }

            // Stem (for non-whole notes)
            if note.duration != .whole {
                let stemX = x + noteRadius
                var stem = Path()
                stem.move(to: CGPoint(x: stemX, y: y))
                stem.addLine(to: CGPoint(x: stemX, y: y - 32))
                context.stroke(stem, with: .color(noteColor), lineWidth: 1.5)
            }

            // Ledger line for middle C (C4)
            if note.pitch == .C && note.octave == 4 {
                var ledger = Path()
                ledger.move(to: CGPoint(x: x - 10, y: staffTop + staffLineSpacing * 5))
                ledger.addLine(to: CGPoint(x: x + 10, y: staffTop + staffLineSpacing * 5))
                context.stroke(ledger, with: .color(noteColor.opacity(0.6)), lineWidth: 1)
            }

            // Accidental indicator
            if !note.pitch.isNatural {
                context.draw(
                    Text("♯")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(noteColor),
                    at: CGPoint(x: x - 14, y: y)
                )
            }

            // Current note highlight ring
            if isCurrent {
                var ring = Path(ellipseIn: noteRect.insetBy(dx: -4, dy: -4))
                context.stroke(ring, with: .color(noteColor.opacity(0.3)), lineWidth: 2)
            }

            // Note label below staff
            context.draw(
                Text(note.pitch.rawValue)
                    .font(.system(size: 10, weight: isCurrent ? .bold : .regular))
                    .foregroundColor(isCurrent ? noteColor : .secondary),
                at: CGPoint(x: x, y: staffTop + staffLineSpacing * 5 + 14)
            )
        }
    }
}
