import SwiftUI

@main
struct TonariApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ChatView()
                .environmentObject(state)
                .frame(width: 420, height: 560)
        } label: {
            Image(systemName: "person.2.fill")
        }
        .menuBarExtraStyle(.window)

        // Settings as a standalone window so clicks inside don't dismiss the
        // menu-bar popover (MenuBarExtra .window style dismisses on focus loss,
        // and .sheet on a popover gets unmounted with it).
        Window("Tonari 設定", id: "settings") {
            SettingsView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 780)
    }
}
