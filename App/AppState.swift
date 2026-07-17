import SwiftUI

// MARK: - App State

class AppState: ObservableObject {
    @Published var selectedInstrument: Instrument? = nil
    @Published var hasCompletedOnboarding: Bool = false
    @Published var selectedTab: AppTab = .home

    enum AppTab {
        case home, lessons, progress, achievements
    }
}

// MARK: - Root View

struct RootView: View {
    // Paper Piano only for now. Onboarding + the Home/Lessons/Progress/Awards
    // tabs are intentionally bypassed (their code is kept for later). To restore
    // the full app, swap this body back to the MainTabView/OnboardingView switch.
    var body: some View {
        NavigationStack {
            PaperPianoView()
        }
    }
}
