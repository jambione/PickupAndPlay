import SwiftUI

// MARK: - Color Palette

extension Color {
    // Primary brand
    static let musePrimary     = Color("MusePrimary")      // deep violet-blue
    static let museAccent      = Color("MuseAccent")       // warm amber
    static let museSuccess     = Color("MuseSuccess")      // green
    static let museWarning     = Color("MuseWarning")      // orange
    static let museDanger      = Color("MuseDanger")       // red

    // Surfaces
    static let museBackground  = Color("MuseBackground")
    static let museSurface     = Color("MuseSurface")
    static let museCard        = Color("MuseCard")

    // Text
    static let museText        = Color("MuseText")
    static let museTextMuted   = Color("MuseTextMuted")

    // Fallback system colors used when asset catalog colors are unavailable
    static let musePrimaryFallback  = Color.indigo
    static let museAccentFallback   = Color.orange
}

// MARK: - Typography

struct MuseFont {
    static func display(_ size: CGFloat = 34) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
    static func title(_ size: CGFloat = 24) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
    static func headline(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }
    static func caption(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }
    static func mono(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

// MARK: - Spacing

enum Spacing {
    static let xs: CGFloat  = 4
    static let sm: CGFloat  = 8
    static let md: CGFloat  = 16
    static let lg: CGFloat  = 24
    static let xl: CGFloat  = 32
    static let xxl: CGFloat = 48
}

// MARK: - Corner Radius

enum Radius {
    static let sm: CGFloat  = 8
    static let md: CGFloat  = 12
    static let lg: CGFloat  = 16
    static let xl: CGFloat  = 24
    static let full: CGFloat = 999
}

// MARK: - Reusable Components

struct MuseCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        content
            .background(Color(.systemBackground))
            .cornerRadius(Radius.lg)
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
}

struct MusePrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(MuseFont.headline())
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.indigo)
            .cornerRadius(Radius.lg)
        }
        .buttonStyle(.plain)
    }
}

struct XPBadge: View {
    let amount: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .bold))
            Text("+\(amount) XP")
                .font(MuseFont.caption(12))
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(Radius.full)
    }
}

struct DifficultyDots: View {
    let level: SkillLevel
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(i < filledDots ? Color.indigo : Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
    var filledDots: Int {
        switch level {
        case .beginner: return 1
        case .earlyIntermediate: return 2
        case .intermediate: return 3
        }
    }
}

struct StreakBadge: View {
    let streak: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .foregroundColor(.orange)
                .font(.system(size: 14, weight: .bold))
            Text("\(streak)")
                .font(MuseFont.headline(15))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(Radius.full)
    }
}
