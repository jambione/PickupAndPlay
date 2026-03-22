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
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.hasCompletedOnboarding {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}
