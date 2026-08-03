import SwiftUI

@main
struct LimitDashboardApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1060, height: 1000)
        // No .windowResizability(.contentMinSize): it derived the window's
        // minimum from the content, and a scroll view is content that is happy
        // at any size, so the floor it produced was meaningless. The window's
        // minimum is set on NSWindow directly instead — see WindowFocusResetter.
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Dashboard") {
                Button("Refresh All") {
                    Task { await model.refresh(showActivity: true) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)
            }
        }
    }
}
