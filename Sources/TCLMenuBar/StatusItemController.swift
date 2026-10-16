import SwiftUI
import AppKit
import Combine

/// What the panel's SwiftUI content needs from the window that hosts it.
@MainActor
final class PanelState: ObservableObject {
    /// True from the moment the panel starts showing until it starts closing.
    @Published var isShown = false
    /// Visible height of the screen the panel opens on, set before it shows.
    @Published var screenHeight: CGFloat?
    /// The in-panel settings page, also opened from the menu bar item's right-click menu.
    @Published var showSettings = false
    /// The content's height, every frame while it animates; the window follows it.
    var onHeightChange: (CGFloat) -> Void = { _ in }
}

/// Owns the menu bar item and its panel. The panel is a plain AppKit window, so its placement (top pinned
/// under the item), size, opening, closing and fades are all set here, never corrected after the fact.
@MainActor
final class StatusItemController: NSObject {
    private let store: AppStore
    private let state = PanelState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: StatusPanel
    private let host: NSHostingView<AirPanel>
    private var height: CGFloat = 0
    private var outsideClickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []

    private static let width: CGFloat = 380
    private static let gap: CGFloat = 4
    private static let cornerRadius: CGFloat = 12

    init(store: AppStore) {
        self.store = store
        panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host = NSHostingView(rootView: AirPanel(store: store, panel: state))
        super.init()

        host.sizingOptions = []   // The window's size is set here, from the reported height, not by Auto Layout.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background
        panel.onCancel = { [weak self] in self?.close() }
        state.onHeightChange = { [weak self] in self?.resize(to: $0) }

        panel.setAccessibilityLabel("TCLimate")
        // Keeps the item's place in the menu bar across launches.
        statusItem.autosaveName = "io.loopbreak.TCLimate.statusitem"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.toolTip = "TCLimate"
        }
        updateButton()
        // Fires before the change lands, so read the new values on the next turn.
        store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateButton() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.close() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.close() }.store(in: &subscriptions)
    }

    // MARK: Menu bar item

    /// The selected unit's reading beside its glyph, or the app icon when the reading is off or unavailable.
    private func updateButton() {
        guard let button = statusItem.button else { return }
        let reading = MenuBarReading(rawValue: UserDefaults.standard.string(forKey: MenuBarReading.storageKey) ?? "") ?? .off
        let selectedID = UserDefaults.standard.string(forKey: "selectedDeviceID") ?? ""
        let unit = store.devices.first { $0.id == selectedID } ?? store.devices.first
        if let unit, let value = reading.value(for: unit) {
            let degrees = value.formatted(.number.precision(.fractionLength(0)))
            let image = reading.glyphImage ?? NSImage(systemSymbolName: reading.symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.title = "\(degrees)°"
            button.setAccessibilityLabel("\(unit.name) \(reading.title.lowercased()) \(degrees) degrees")
        } else {
            button.image = MenuBarIcon.image
            button.title = ""
            button.setAccessibilityLabel("TCLimate")
        }
    }

    // MARK: Panel

    /// Left click toggles the panel; right click offers the commands that work even when the panel is in the way.
    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu() } else { toggle() }
    }

    private func toggle() {
        panel.isVisible && state.isShown ? close() : show()
    }

    private func showContextMenu() {
        close()
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open TCLimate", action: #selector(openPanel), keyEquivalent: "").target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = store.connected
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TCLimate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func openPanel() { show() }

    @objc private func openSettings() {
        state.showSettings = true
        show()
    }

    /// Opening the app again (Finder, Spotlight) shows the panel, so it stays reachable when macOS hides the item.
    func reopen() { show() }

    func show() {
        guard !state.isShown || !panel.isVisible else { return }
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        state.screenHeight = screen?.visibleFrame.height
        // Applies the screen's height cap and settles the layout before the window is placed.
        host.layoutSubtreeIfNeeded()
        if height == 0 { height = host.fittingSize.height }
        place()
        state.isShown = true
        statusItem.button?.highlight(true)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        startOutsideClickMonitor()
    }

    private func close() {
        guard state.isShown else { return }
        state.isShown = false
        statusItem.button?.highlight(false)
        stopOutsideClickMonitor()
        let panel = panel
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Reopened while fading out: keep it.
            MainActor.assumeIsolated { if self?.state.isShown == false { panel.orderOut(nil) } }
        }
    }

    private func resize(to newHeight: CGFloat) {
        height = newHeight
        if panel.isVisible { place() }
    }

    /// Top edge just under the menu bar, left edge on the item's, kept on screen. When macOS hides the item
    /// (System Settings → Menu Bar, or no room beside the notch), the panel opens at the main screen's top right.
    private func place() {
        let buttonWindow = statusItem.button?.window
        let itemScreen = buttonWindow?.screen
        guard let screen = itemScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let anchor = itemScreen != nil ? buttonWindow?.frame : nil
        let height = height.rounded(.up)
        let x = min(max(anchor?.minX ?? visible.maxX, visible.minX + 8), visible.maxX - Self.width - 8)
        let top = (anchor?.minY ?? visible.maxY) - Self.gap
        let frame = NSRect(x: x, y: top - height, width: Self.width, height: height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// Closes on a click in another app's window or menu bar item. While the sign-in form has focus, the password
    /// manager's AutoFill popup (another process) gets that click, so it is ignored then; switching apps still closes.
    /// The menu bar draws status items out of process, so a click on our own item arrives here too; `toggle` handles that one.
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.statusItem.button?.window?.frame.contains(NSEvent.mouseLocation) == true { return }
                if !self.store.connected, self.panel.firstResponder is NSText { return }
                self.close()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    /// A stretchable rounded rectangle; the window's shadow follows it.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A borderless panel that can take keyboard focus (the sign-in fields, shortcuts) and closes on Escape.
private final class StatusPanel: NSPanel {
    var onCancel: () -> Void = {}

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .floatingWindow }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}
