import SwiftUI

// MARK: - Virtual Piano Keyboard Overlay

/// The beautiful on-screen piano that responds to paper key presses.
/// Rendered in SwiftUI using Canvas for crisp, GPU-accelerated drawing.
struct VirtualPianoView: View {
    let activeNotes: [ActiveNote]
    var onKeyTap: ((PaperPianoKey) -> Void)? = nil

    private let whites: [PaperPianoKey]
    private let blacks: [PaperPianoKey]

    init(activeNotes: [ActiveNote],
         variant: KeyboardVariant = .threeOctave,
         onKeyTap: ((PaperPianoKey) -> Void)? = nil) {
        self.activeNotes = activeNotes
        self.onKeyTap = onKeyTap
        let layout = PaperPianoKey.layout(for: variant)
        whites = layout.filter { !$0.isBlack }
        blacks = layout.filter { $0.isBlack }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // White keys
                ForEach(whites) { key in
                    WhiteKeyView(
                        key: key,
                        isActive: isActive(key),
                        totalWhiteKeys: whites.count,
                        containerSize: geo.size
                    )
                    .onTapGesture { onKeyTap?(key) }
                }
                // Black keys drawn on top
                ForEach(blacks) { key in
                    BlackKeyView(
                        key: key,
                        isActive: isActive(key),
                        totalWhiteKeys: whites.count,
                        containerSize: geo.size
                    )
                    .onTapGesture { onKeyTap?(key) }
                }
            }
        }
    }

    private func isActive(_ key: PaperPianoKey) -> Bool {
        activeNotes.contains { $0.key.id == key.id }
    }
}

// MARK: - White Key View

private struct WhiteKeyView: View {
    let key: PaperPianoKey
    let isActive: Bool
    let totalWhiteKeys: Int
    let containerSize: CGSize

    private var keyWidth: CGFloat { containerSize.width / CGFloat(totalWhiteKeys) }
    private var x: CGFloat { keyWidth * CGFloat(key.whiteKeyIndex) }

    var body: some View {
        let w = keyWidth - 1.5
        let h = containerSize.height

        ZStack(alignment: .bottom) {
            // Base key
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isActive ? activeGradient : normalGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.black.opacity(0.25), lineWidth: 1)
                )

            // Glow when active
            if isActive {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.indigo.opacity(0.3))
                    .blur(radius: 6)
                    .scaleEffect(1.05)
            }

            // Note label
            VStack {
                Spacer()
                Text(key.displayName)
                    .font(.system(size: max(8, keyWidth * 0.32), weight: isActive ? .bold : .medium,
                                  design: .rounded))
                    .foregroundColor(isActive ? .indigo : .gray)
                    .padding(.bottom, 5)
            }
        }
        .frame(width: w, height: h)
        .position(x: x + w / 2 + 0.75, y: h / 2)
        .animation(.spring(response: 0.12, dampingFraction: 0.6), value: isActive)
        .scaleEffect(isActive ? CGSize(width: 1.0, height: 0.97) : CGSize(width: 1.0, height: 1.0),
                     anchor: .top)
    }

    private var normalGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white, Color(white: 0.93)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var activeGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.9, green: 0.91, blue: 1.0),
                     Color(red: 0.75, green: 0.77, blue: 0.98)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Black Key View

private struct BlackKeyView: View {
    let key: PaperPianoKey
    let isActive: Bool
    let totalWhiteKeys: Int
    let containerSize: CGSize

    private var whiteKeyWidth: CGFloat { containerSize.width / CGFloat(totalWhiteKeys) }
    private var keyWidth: CGFloat { whiteKeyWidth * 0.60 }
    private var keyHeight: CGFloat { containerSize.height * 0.62 }

    // Position: centered at the gap between left white key and the next
    private var x: CGFloat {
        whiteKeyWidth * CGFloat(key.whiteKeyIndex) + whiteKeyWidth - keyWidth / 2
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Shadow underneath
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.black.opacity(0.5))
                .offset(y: 3)
                .blur(radius: 2)

            // Key body
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isActive ? blackActiveGradient : blackNormalGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.black.opacity(0.8), lineWidth: 1)
                )

            // Glow
            if isActive {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.purple.opacity(0.5))
                    .blur(radius: 5)
                    .scaleEffect(1.1)
            }

            // Label
            Text(key.note.rawValue)
                .font(.system(size: max(6, keyWidth * 0.28), weight: .medium, design: .rounded))
                .foregroundColor(isActive ? Color(red: 0.8, green: 0.8, blue: 1.0) : Color.gray.opacity(0.7))
                .padding(.bottom, 4)
        }
        .frame(width: keyWidth, height: keyHeight)
        .position(x: x + keyWidth / 2, y: keyHeight / 2)
        .animation(.spring(response: 0.1, dampingFraction: 0.5), value: isActive)
        .scaleEffect(isActive ? CGSize(width: 1.0, height: 0.96) : .init(width: 1, height: 1),
                     anchor: .top)
        .zIndex(1)
    }

    private var blackNormalGradient: LinearGradient {
        LinearGradient(
            colors: [Color(white: 0.18), Color(white: 0.08)],
            startPoint: .top, endPoint: .bottom
        )
    }
    private var blackActiveGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.25, green: 0.22, blue: 0.55),
                     Color(red: 0.12, green: 0.10, blue: 0.35)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Note Ripple Overlay

/// Shows a ripple animation at a key position when it's struck
struct NoteRippleOverlay: View {
    let activeNotes: [ActiveNote]
    let containerSize: CGSize
    var variant: KeyboardVariant = .threeOctave

    private var totalWhites: Int {
        PaperPianoKey.layout(for: variant).filter { !$0.isBlack }.count
    }

    var body: some View {
        ZStack {
            ForEach(activeNotes) { note in
                let x = rippleX(for: note.key)
                let y: CGFloat = note.key.isBlack
                    ? containerSize.height * 0.31
                    : containerSize.height * 0.5

                RippleView()
                    .frame(width: 50, height: 50)
                    .position(x: x, y: y)
            }
        }
    }

    private func rippleX(for key: PaperPianoKey) -> CGFloat {
        let ww = containerSize.width / CGFloat(totalWhites)
        if key.isBlack {
            return ww * CGFloat(key.whiteKeyIndex) + ww - ww * 0.3
        } else {
            return ww * CGFloat(key.whiteKeyIndex) + ww / 2
        }
    }
}

private struct RippleView: View {
    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0.8

    var body: some View {
        Circle()
            .fill(Color.indigo.opacity(opacity))
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeOut(duration: 0.5)) {
                    scale = 1.8
                    opacity = 0
                }
            }
    }
}

// MARK: - Active Note Display Bar

struct ActiveNoteBar: View {
    let activeNotes: [ActiveNote]

    var body: some View {
        HStack(spacing: 6) {
            if activeNotes.isEmpty {
                Text("Play a key")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            } else {
                ForEach(activeNotes) { note in
                    NoteChip(note: note)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.2), value: activeNotes.map(\.key.id))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct NoteChip: View {
    let note: ActiveNote
    var body: some View {
        Text(note.key.displayName)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                note.key.isBlack
                ? Color.purple
                : Color.indigo
            )
            .clipShape(Capsule())
    }
}
