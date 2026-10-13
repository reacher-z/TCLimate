import SwiftUI
import AppKit
import TCLCore

/// Builds the panel once, off-screen, shortly after launch. The first build loads fonts, symbols and SwiftUI
/// machinery (about half a second); doing it here means the first click opens a panel that is already warm.
@MainActor
enum PanelWarmUp {
    private static var done = false

    static func run() {
        guard !done else { return }
        done = true
        let store = AppStore()
        store.connected = true
        store.devices = [AirConditioner.warmUpSample, AirConditioner.warmUpSample]
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 380, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AirPanel(store: store))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.contentView = nil
    }
}
