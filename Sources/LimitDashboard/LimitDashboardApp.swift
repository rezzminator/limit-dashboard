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
        .windowResizability(.contentMinSize)
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
