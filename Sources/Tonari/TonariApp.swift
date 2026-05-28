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
            Image(systemName: "bubble.left.and.bubble.right.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
