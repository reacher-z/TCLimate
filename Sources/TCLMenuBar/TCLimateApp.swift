import SwiftUI
import AppKit

@main
struct TCLimateApp: App {
    @StateObject private var store = AppStore()

    init() {
        MenuBarReading.migrateLegacySetting()
    }

    var body: some Scene {
        MenuBarExtra {
            AirPanel(store: store)
                .task { await store.restore() }
        } label: {
            // The menu bar item exists from launch, so sign-in and the first device fetch finish before the first click.
            MenuBarLabel(store: store)
                .task { await store.restore() }
                .task {
                    // Let the menu bar item draw first, then pre-build the panel.
                    try? await Task.sleep(for: .milliseconds(400))
                    PanelWarmUp.run()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
