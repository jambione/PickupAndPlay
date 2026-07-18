import SwiftUI

// MARK: - Generic Zone Board

/// On-screen renderer for non-piano instrument families (drums, mallets,
/// zither, …). Driven purely by `normalizedFrame`/`displayLabel` — the same
/// source of truth `KeyboardCalibration.key(at:)` and `KeyboardProjectionOverlay`
/// already use — so a new `KeyboardVariant` needs no bespoke view geometry the
/// way `VirtualPianoView`'s piano-shaped `WhiteKeyView`/`BlackKeyView` do.
struct ZoneBoardView: View {
    let activeNotes: [ActiveNote]
    var onZoneTap: ((PaperPianoKey) -> Void)? = nil

    private let zones: [PaperPianoKey]

    init(activeNotes: [ActiveNote],
         variant: KeyboardVariant,
         onZoneTap: ((PaperPianoKey) -> Void)? = nil) {
        self.activeNotes = activeNotes
        self.onZoneTap = onZoneTap
        zones = PaperPianoKey.layout(for: variant)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(zones) { zone in
                    ZonePadView(zone: zone, isActive: isActive(zone), containerSize: geo.size)
                        .onTapGesture { onZoneTap?(zone) }
                }
            }
        }
    }

    private func isActive(_ zone: PaperPianoKey) -> Bool {
        activeNotes.contains { $0.key.id == zone.id }
    }
}

// MARK: - Zone Pad View

private struct ZonePadView: View {
    let zone: PaperPianoKey
    let isActive: Bool
    let containerSize: CGSize

    private var frame: CGRect {
        CGRect(x: zone.normalizedFrame.minX * containerSize.width,
              y: zone.normalizedFrame.minY * containerSize.height,
              width: zone.normalizedFrame.width * containerSize.width,
              height: zone.normalizedFrame.height * containerSize.height)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? activeGradient : normalGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.25), lineWidth: 1)
                )

            if isActive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.indigo.opacity(0.35))
                    .blur(radius: 8)
            }

            Text(zone.displayName)
                .font(.system(size: max(9, min(frame.width, frame.height) * 0.22),
                             weight: isActive ? .bold : .semibold, design: .rounded))
                .foregroundColor(isActive ? .white : .primary.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 4)
        }
        .frame(width: max(2, frame.width - 3), height: max(2, frame.height - 3))
        .position(x: frame.midX, y: frame.midY)
        .animation(.spring(response: 0.12, dampingFraction: 0.55), value: isActive)
        .scaleEffect(isActive ? 0.96 : 1.0)
    }

    private var normalGradient: LinearGradient {
        LinearGradient(colors: [Color(white: 0.85), Color(white: 0.68)],
                       startPoint: .top, endPoint: .bottom)
    }
    private var activeGradient: LinearGradient {
        LinearGradient(colors: [Color.indigo, Color.purple],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Zone Ripple Overlay

/// Generic hit-feedback ripple, positioned from `normalizedFrame`'s center
/// rather than piano-specific white/black-key column math.
struct ZoneRippleOverlay: View {
    let activeNotes: [ActiveNote]
    let containerSize: CGSize

    var body: some View {
        ZStack {
            ForEach(activeNotes) { note in
                let center = CGPoint(
                    x: note.key.normalizedFrame.midX * containerSize.width,
                    y: note.key.normalizedFrame.midY * containerSize.height)
                ZoneRippleView()
                    .frame(width: 50, height: 50)
                    .position(center)
            }
        }
    }
}

private struct ZoneRippleView: View {
    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0.8

    var body: some View {
        Circle()
            .fill(Color.indigo.opacity(opacity))
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4)) {
                    scale = 1.8
                    opacity = 0
                }
            }
    }
}
