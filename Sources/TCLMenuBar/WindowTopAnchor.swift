import SwiftUI
import AppKit

/// Keeps the menu bar window's top edge just under the menu bar of whichever screen it's on.
/// AppKit resizes windows around a fixed bottom-left origin, and MenuBarExtra doesn't re-anchor
/// when its content height changes, which otherwise opens a gap below the menu bar.
/// The top is derived from the screen each time (not remembered), so it stays right across
/// screens, sign-in/out and reopening. MenuBarExtra also keeps a taller frame after the content
/// shrinks (e.g. devices → sign-in), centering the content in it, so `height` resizes the window too.
/// Opening fades in.
struct WindowTopAnchor: NSViewRepresentable {
    var height: CGFloat?
    /// While true (the sign-in form), a close caused by clicking the password manager's AutoFill popup is undone.
    var keepOpenForAutoFill = false

    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? AnchorView else { return }
        view.keepOpenForAutoFill = keepOpenForAutoFill
        guard view.height != height else { return }
        view.height = height
        // Applied in the same pass (not on the next run loop turn), so mid-animation heights never lag the content by a frame.
        view.anchor()
    }

    fileprivate final class AnchorView: NSView {
        var height: CGFloat?
        var keepOpenForAutoFill = false
        private var fadePending = false
        private var retryScheduled = false
        private var visibilityObservation: NSKeyValueObservation?
        private var gap: CGFloat?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.anchor()
                    }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.anchor()
                    self?.fadeIn()
                }
            })
            visibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] window, change in
                guard change.newValue == false else { return }
                MainActor.assumeIsolated { self?.reopenIfAutoFillClosedIt(window) }
            }
            anchor()
        }

        /// MenuBarExtra closes its window on any click outside it, including a click in the password manager's
        /// AutoFill popup (another process's window), which also makes the fields unusable. If we're still the frontmost
        /// app and the click wasn't on the status icon or the window itself, the close wasn't meant: bring the panel back.
        private func reopenIfAutoFillClosedIt(_ window: NSWindow) {
            guard keepOpenForAutoFill, window.firstResponder is NSText else { return }
            DispatchQueue.main.async {
                let mouse = NSEvent.mouseLocation
                let onIcon = NSApp.windows.contains { String(describing: type(of: $0)).contains("StatusBar") && $0.frame.contains(mouse) }
                guard !window.isVisible, !onIcon else { return }
                guard NSWorkspace.shared.frontmostApplication == .current else { return }
                window.alphaValue = 1
                window.orderFrontRegardless()
                window.makeKey()
            }
        }

        /// Fades the panel in, with no movement, matching the fades inside it. Skipped with Reduce Motion.
        /// On the first open the window becomes key while still 32pt tall, before the content is measured,
        /// so the fade waits for the final height rather than showing the stub growing.
        private func fadeIn() {
            guard let window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            window.alphaValue = 0
            fadePending = true
            startFadeIfReady()
            // Never leave the panel hidden if the final height doesn't arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startFadeIfReady(force: true) }
        }

        private func startFadeIfReady(force: Bool = false) {
            guard fadePending, let window else { return }
            // Ready once the window is on screen (its layer attached) at the measured height. Until then, check again
            // on the next run loop turn, since nothing else may call back after the layer attaches.
            let ready = window.contentView?.layer?.superlayer != nil
                && height.map { abs(window.frame.height - $0.rounded(.up)) <= 0.5 } == true
            guard ready || force else {
                guard !retryScheduled else { return }
                retryScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) { [weak self] in
                    self?.retryScheduled = false
                    self?.startFadeIfReady()
                }
                return
            }
            fadePending = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            } completionHandler: {
                // Never leave the panel see-through, even if the animation is interrupted.
                MainActor.assumeIsolated { window.alphaValue = 1 }
            }
        }

        func anchor() {
            defer { startFadeIfReady() }
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            // Bottom of the menu bar; with an auto-hiding menu bar, visibleFrame reaches the top edge.
            let menuBarBottom = screen.visibleFrame.maxY < screen.frame.maxY
                ? screen.visibleFrame.maxY
                : screen.frame.maxY - NSStatusBar.system.thickness
            // Keep the system's own spacing from the first correct placement.
            if gap == nil {
                let measured = menuBarBottom - window.frame.maxY
                gap = (0...12).contains(measured) ? measured : 4
            }
            let top = menuBarBottom - (gap ?? 4)
            let height = (self.height ?? window.frame.height).rounded(.up)
            guard abs(window.frame.maxY - top) > 0.5 || abs(window.frame.height - height) > 0.5 else { return }
            let target = NSRect(x: window.frame.minX, y: top - height, width: window.frame.width, height: height)
            window.setFrame(target, display: true)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
