import SwiftUI

@main
struct TapNoteApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var userProgress = UserProgressStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(userProgress)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 750)
        #endif
    }
}
