import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var userProgress: UserProgressStore
    @State private var currentPage = 0
    @State private var selectedInstrument: Instrument? = nil

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()

            TabView(selection: $currentPage) {
                WelcomePage()
                    .tag(0)

                InstrumentPickerPage(selectedInstrument: $selectedInstrument)
                    .tag(1)

                GoalsPage(onFinish: finishOnboarding)
                    .tag(2)
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .animation(.easeInOut, value: currentPage)

            // Navigation
            VStack {
                Spacer()
                if currentPage < 2 {
                    MusePrimaryButton("Continue", icon: "arrow.right") {
                        withAnimation { currentPage += 1 }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xl)
                }
            }

            // Page dots
            VStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(i == currentPage ? Color.indigo : Color.gray.opacity(0.3))
                            .frame(width: 7, height: 7)
                            .animation(.spring(), value: currentPage)
                    }
                }
                .padding(.top, Spacing.lg)
                Spacer()
            }
        }
    }

    private func finishOnboarding() {
        if let instrument = selectedInstrument {
            userProgress.selectedInstrument = instrument
            appState.selectedInstrument = instrument
        }
        withAnimation(.spring()) {
            appState.hasCompletedOnboarding = true
        }
    }
}

// MARK: - Welcome Page

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 72, weight: .light))
                .foregroundColor(.indigo)
                .padding(.bottom, Spacing.md)

            Text("Welcome to TapNote")
                .font(MuseFont.display())
                .multilineTextAlignment(.center)

            Text("Learn to read and play music — one lesson at a time. It's fun, visual, and designed for real progress.")
                .font(MuseFont.body())
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            Spacer()
            Spacer()
        }
        .padding()
    }
}

// MARK: - Instrument Picker Page

private struct InstrumentPickerPage: View {
    @Binding var selectedInstrument: Instrument?

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Text("Choose Your Instrument")
                .font(MuseFont.display(28))
                .multilineTextAlignment(.center)

            Text("You can add more instruments later")
                .font(MuseFont.body())
                .foregroundColor(.secondary)

            Spacer().frame(height: Spacing.md)

            ForEach(Instrument.allCases) { instrument in
                InstrumentOptionCard(
                    instrument: instrument,
                    isSelected: selectedInstrument == instrument
                ) {
                    selectedInstrument = instrument
                }
            }
            .padding(.horizontal, Spacing.xl)
            Spacer()
            Spacer()
        }
        .padding()
    }
}

private struct InstrumentOptionCard: View {
    let instrument: Instrument
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: instrument.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(isSelected ? .white : .indigo)
                    .frame(width: 56, height: 56)
                    .background(isSelected ? Color.indigo : Color.indigo.opacity(0.1))
                    .cornerRadius(Radius.md)

                VStack(alignment: .leading, spacing: 4) {
                    Text(instrument.rawValue)
                        .font(MuseFont.headline())
                        .foregroundColor(.primary)
                    Text(instrument.description)
                        .font(MuseFont.body(14))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.indigo)
                        .font(.system(size: 22))
                }
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .fill(Color(UIColor.systemBackground))
                    .shadow(color: isSelected ? .indigo.opacity(0.2) : .black.opacity(0.05),
                            radius: isSelected ? 8 : 4, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .stroke(isSelected ? Color.indigo : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Goals Page

private struct GoalsPage: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "target")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.indigo)

            Text("Set Your Goal")
                .font(MuseFont.display(28))
                .multilineTextAlignment(.center)

            VStack(spacing: Spacing.md) {
                GoalFeatureRow(icon: "bolt.fill", color: .orange,
                               title: "Earn XP every day",
                               subtitle: "Hit your daily XP goal to level up faster")
                GoalFeatureRow(icon: "flame.fill", color: .red,
                               title: "Build your streak",
                               subtitle: "Consistent practice is the secret to progress")
                GoalFeatureRow(icon: "star.fill", color: .yellow,
                               title: "Unlock achievements",
                               subtitle: "Celebrate every milestone along the way")
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()

            MusePrimaryButton("Let's Begin", icon: "play.fill", action: onFinish)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
        }
        .padding()
    }
}

private struct GoalFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(color.opacity(0.1))
                .cornerRadius(Radius.sm)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MuseFont.headline())
                Text(subtitle).font(MuseFont.body(14)).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}
