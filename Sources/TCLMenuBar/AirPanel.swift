import SwiftUI
import AppKit
import Combine
import TCLCore

struct AirPanel: View {
    @ObservedObject var store: AppStore
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @State private var contentHeight: CGFloat?
    /// The panel's rendered height, including mid-animation values, so the window resizes in step with the content.
    @State private var panelHeight: CGFloat?
    @AppStorage("selectedDeviceID") private var selectedDeviceID = ""
    @State private var showSettings = false
    @State private var screenHeight: CGFloat?
    private let poll = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            // An explicit height lets MenuBarExtra size its window; scrolls past the cap.
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .environment(\.scrollToSection) { id in
                            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(height: contentHeight.map { min($0, heightCap) })
                // Height changes apply at once (the window follows with its top pinned); only content fades, never slides.
                .animation(nil, value: contentHeight)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = (contentHeight ?? 0) > 0 ? $0 : nil }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .top)
        .tint(.gray)
        .background(WindowTopAnchor(height: panelHeight, keepOpenForAutoFill: !store.connected))
        .onAppear { launchAtLogin.refresh(); updateScreenHeight() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
            updateScreenHeight()
        }
        .onReceive(poll) { _ in
            if NSApplication.shared.keyWindow?.isVisible == true { Task { await store.refresh() } }
        }
        .background(shortcuts)
        .onChange(of: store.connected) { _, connected in if !connected { showSettings = false } }
    }

    private var selectedDevice: AirConditioner? { store.devices.first { $0.id == selectedDeviceID } ?? store.devices.first }

    /// Keyboard control: ⌘↑/⌘↓ change the selected unit's target, ⌘1–⌘3 switch units.
    /// The buttons are invisible and take no layout space.
    private var shortcuts: some View {
        ZStack {
            Button("Raise temperature") { nudge(1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Lower temperature") { nudge(-1) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("Unit 1") { select(0) }.keyboardShortcut("1", modifiers: .command)
            Button("Unit 2") { select(1) }.keyboardShortcut("2", modifiers: .command)
            Button("Unit 3") { select(2) }.keyboardShortcut("3", modifiers: .command)
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private func nudge(_ delta: Double) {
        guard let device = selectedDevice, device.isOnline, device.isSupported, device.power,
              let target = device.targetTemperature else { return }
        let next = target + delta
        guard (device.minTemperature...device.maxTemperature).contains(next) else { return }
        store.send(.temperature(next), to: device)
    }

    private func select(_ index: Int) {
        guard store.devices.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { selectedDeviceID = store.devices[index].id }
    }

    /// How tall the scrolling area may get: most of the screen the panel opened on, so a full device card fits
    /// without scrolling where there is room. It never exceeds that screen; shorter screens scroll instead.
    private var heightCap: CGFloat {
        let available = (screenHeight ?? NSScreen.main?.visibleFrame.height ?? 800) - 90
        return max(min(available, 760), 200)
    }

    /// The screen whose menu bar was clicked (the pointer is on it when the panel opens), not `NSScreen.main`,
    /// which can be another display before the panel becomes key.
    private func updateScreenHeight() {
        let mouse = NSEvent.mouseLocation
        screenHeight = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame.height
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            // Overlaid rather than stacked, so the outgoing and incoming pages cross-fade in place instead of
            // the new page sliding up as the old one leaves.
            ZStack(alignment: .top) {
                if showSettings {
                    SettingsPage(store: store, launchAtLogin: launchAtLogin, selectedDevice: selectedDevice)
                        .transition(.opacity)
                } else if store.connected {
                    VStack(alignment: .leading, spacing: 10) { devices }.transition(.opacity)
                } else {
                    SignInForm(store: store).transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 4)
        // Sign-in → connecting → units cross-fade instead of swapping.
        .animation(.easeInOut(duration: 0.4), value: store.connected)
        .animation(.easeInOut(duration: 0.25), value: store.connectStep)
    }

    private var header: some View {
        HStack(spacing: 4) {
            if showSettings {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showSettings = false } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Settings").font(.system(size: 13, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back")
            } else {
                Text("TCLimate").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            if store.connected && !showSettings {
                Button { Task { await store.refresh() } } label: {
                    if store.busy { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(HeaderButtonStyle())
                .disabled(store.busy || !store.pendingDevices.isEmpty)
                .help(updatedHelp)
                .keyboardShortcut("r")
            }
            // In Settings the back button closes it, so the gear is only shown outside it.
            if !showSettings {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showSettings = true } } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(HeaderButtonStyle())
                .keyboardShortcut(",")
                .help("Settings")
            }
        }
        .frame(height: 26) // Header buttons' height, so Settings (no buttons) doesn't shift the content.
        .padding(.leading, 14).padding(.trailing, 8).padding(.top, 6)
    }

    private var updatedHelp: String {
        guard let date = store.lastUpdated else { return "Refresh" }
        return "Refresh · Updated \(date.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder private var status: some View {
        if let error = launchAtLogin.error {
            Banner(text: error, symbol: "exclamationmark.triangle.fill", tint: .red)
        } else if launchAtLogin.requiresApproval {
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch at login needs approval in System Settings.").font(.caption)
                Button("Open Login Items…") { launchAtLogin.openSettings() }
                    .font(.caption)
            }
        }
        if let error = store.error {
            Banner(text: error, symbol: "exclamationmark.triangle.fill", tint: .red)
        } else if let notice = store.notice {
            Banner(text: notice, symbol: "info.circle", tint: .secondary)
        }
    }

    @ViewBuilder private var devices: some View {
        if store.devices.isEmpty {
            VStack(spacing: 6) {
                ACGlyph(active: false, width: 36)
                Text("No air conditioners").font(.headline)
                Text("Pair your ACs with this account in the TCL Home app, then refresh.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 24)
        }
        if store.devices.count > 1 { DeviceSwitcher(devices: store.devices, selection: $selectedDeviceID) }
        if let device = store.devices.first(where: { $0.id == selectedDeviceID }) ?? store.devices.first {
            DeviceCard(energyStore: store, device: device, showsName: store.devices.count < 2, pending: store.pendingDevices.contains(device.id),
                       unconfirmed: store.unconfirmedDevices.contains(device.id)) { command in
                store.send(command, to: device)
            }
            .id(device.id)
            .transition(.opacity)
        }
    }
}

/// Bare icon button; a soft highlight appears only on hover or press.
private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct HoverIcon<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hovering = false

        var body: some View {
            label
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.primary.opacity(pressed ? 0.12 : hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Monochrome primary action: inverted label on a solid primary fill.
private struct MonoProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.background)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(.primary.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.3)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Snowflake, optionally followed by the selected unit's room temperature.
/// What the menu bar item shows next to its icon. Stored as a string so the choice survives relaunches.
enum MenuBarReading: String, CaseIterable, Identifiable {
    case off, target, room, outdoor
    var id: String { rawValue }
    static let storageKey = "menuBarReading"

    var title: String {
        switch self {
        case .off: return "Icon Only"
        case .target: return "Set Temperature"
        case .room: return "Room Temperature"
        case .outdoor: return "Outdoor Temperature"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: return "Icon only"
        case .target: return "Set"
        case .room: return "Room"
        case .outdoor: return "Outdoor"
        }
    }

    /// Custom drawn icon for readings that have one; the others use `symbol`.
    var glyphImage: NSImage? { self == .target ? MenuBarIcon.splitOutlet : nil }

    /// Symbol for the menu item. The menu bar uses the custom split-unit glyph for the set temperature.
    var symbol: String {
        switch self {
        case .off: return "snowflake"
        case .target: return "thermometer.medium"
        case .room: return "house"
        case .outdoor: return "sun.max"
        }
    }

    /// The value to show for `unit`, or nil when there is nothing meaningful to show.
    /// Set and outdoor temperatures only show while the unit runs; the outdoor reading is stale when it's off.
    func value(for unit: AirConditioner) -> Double? {
        guard unit.isOnline else { return nil }
        switch self {
        case .off: return nil
        case .target: return unit.power ? unit.targetTemperature : nil
        case .room: return unit.currentTemperature
        case .outdoor: return unit.power ? unit.outdoorTemperature : nil
        }
    }

    /// Carries the earlier on/off setting over as Room Temperature.
    static func migrateLegacySetting() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: storageKey) == nil, defaults.bool(forKey: "showTempInMenuBar") else { return }
        defaults.set(MenuBarReading.room.rawValue, forKey: storageKey)
        defaults.removeObject(forKey: "showTempInMenuBar")
    }
}

/// The menu bar item: the snowflake, or a reading with an icon saying what it is.
struct MenuBarLabel: View {
    @ObservedObject var store: AppStore
    @AppStorage(MenuBarReading.storageKey) private var reading: MenuBarReading = .off
    @AppStorage("selectedDeviceID") private var selectedDeviceID = ""

    private var selected: AirConditioner? { store.devices.first { $0.id == selectedDeviceID } ?? store.devices.first }

    var body: some View {
        if let unit = selected, let value = reading.value(for: unit) {
            let degrees = value.formatted(.number.precision(.fractionLength(0)))
            HStack(spacing: 4) {
                // Each reading has its own icon: the unit for its set temperature, a house for the room, the sun for outdoors.
                if let image = reading.glyphImage { Image(nsImage: image) } else { Image(systemName: reading.symbol) }
                Text("\(degrees)°")
            }
            .accessibilityLabel("\(unit.name) \(reading.title.lowercased()) \(degrees) degrees")
        } else {
            Image(nsImage: MenuBarIcon.image).accessibilityLabel("TCLimate")
        }
    }
}

/// One louver's motion (the flap's tilt or the fins' side-to-side), continuous across setting changes:
/// a swing starts from wherever it is, stopping holds it there, and a new position glides from it.
private struct LouverMotion {
    enum Wave { case tilt, side }
    enum Target { case swing, position(Double), hold }

    let wave: Wave
    private var from: Double
    private var to: Double
    private var start = Date.distantPast
    private var swingStart: Date?
    private var phase = 0.0
    private static let glide = 0.7

    init(wave: Wave, value: Double) {
        self.wave = wave
        from = value
        to = value
    }

    /// The tilt rocks over 0…1 (cosine), the fins over −1…1 (sine); both start at `phase` for the current value.
    private func shape(_ x: Double) -> Double { wave == .tilt ? (1 + cos(x)) / 2 : sin(x) }
    private var speed: Double { wave == .tilt ? 0.5 : 0.4 }   // slow, unhurried sweeps

    func value(at now: Date, still: Bool) -> Double {
        if let swingStart {
            return shape(phase + (still ? 0 : now.timeIntervalSince(swingStart) * speed))
        }
        let t = still ? 1 : min(1, max(0, now.timeIntervalSince(start) / Self.glide))
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        return from + (to - from) * eased
    }

    mutating func apply(_ target: Target?, at now: Date) {
        let current = value(at: now, still: false)
        swingStart = nil
        switch target {
        case .swing:
            let clamped = wave == .tilt ? min(max(current, 0), 1) : min(max(current, -1), 1)
            phase = wave == .tilt ? acos(2 * clamped - 1) : asin(clamped)
            swingStart = now
        case .position(let value):
            from = current; to = value; start = now
        case .hold, nil:
            from = current; to = current; start = now
        }
    }
}

/// Lets a card bring one of its expanded sections into view inside the panel's scroll view.
private struct ScrollToSectionKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var scrollToSection: (String) -> Void {
        get { self[ScrollToSectionKey.self] }
        set { self[ScrollToSectionKey.self] = newValue }
    }
}

private struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label { Text(text).foregroundStyle(.primary) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SignInForm: View {
    @ObservedObject var store: AppStore
    @State private var revealPassword = false
    @FocusState private var emailFocused: Bool
    @State private var hintOpacity = 0.0
    private var canSubmit: Bool {
        !store.busy && isValidEmail(store.email) && !store.password.isEmpty
    }
    // Only judge the email once the person has left the field, not while they are still typing it.
    private var showsEmailHint: Bool {
        !emailFocused && !store.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidEmail(store.email)
    }

    var body: some View {
        // Once connected, keep the progress view while this fades out, rather than flashing the form back.
        if let step = store.connectStep ?? (store.connected ? .findingDevices : nil) {
            ConnectingView(step: step, email: store.email) { store.cancelConnect() }
        } else {
            form
        }
    }

    private var form: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                BrandMark(size: 52)
                Text("Sign in to TCL Home").font(.title3.weight(.semibold))
                Text("Use the account your air conditioners are paired with.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            VStack(spacing: 0) {
                row("envelope") {
                    TextField("Email", text: $store.email).textContentType(.username).focused($emailFocused)
                }
                Divider().padding(.leading, 36)
                row("lock") {
                    Group {
                        if revealPassword { TextField("TCL password", text: $store.password) }
                        else { SecureField("TCL password", text: $store.password) }
                    }
                    .textContentType(.password)
                    .onSubmit { if canSubmit { Task { await store.signIn() } } }
                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help(revealPassword ? "Hide Password" : "Show Password")
                }
                Divider().padding(.leading, 36)
                row("globe") {
                    Text("Region").foregroundStyle(.secondary)
                    Spacer()
                    // A borderless menu reads as part of the field group rather than a separate push button.
                    Menu {
                        Picker("Region", selection: $store.region) {
                            ForEach(regions, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: {
                        Text(regions.first { $0.0 == store.region }?.1 ?? "")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .textFieldStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))

            // Takes space only while shown. Inserted without animation so nothing below slides; the text itself fades in.
            if showsEmailHint {
                Text("Enter a valid email address.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                    .opacity(hintOpacity)
                    .onAppear { hintOpacity = 0; withAnimation(.easeOut(duration: 0.15)) { hintOpacity = 1 } }
            }

            // A compact switch row matching the field group's insets, instead of a bare checkbox.
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stay signed in")
                    Text("Saves your password in Keychain").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Stay signed in", isOn: $store.remember)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            .padding(.horizontal, 10)

            Button { Task { await store.signIn() } } label: {
                Label("Sign In", systemImage: "arrow.right.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(MonoProminentButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)

            Label {
                Text("Signed in with Google or Apple? Set a TCL password in TCL Home › Account Security and use it here. Never enter your Google or Apple password.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private let regions: [(AccountRegion, String)] = [
        (.singapore, "Pakistan / Singapore"), (.europe, "Europe"), (.usa, "United States"),
    ]

    private func row<Content: View>(_ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            content()
        }
        .padding(.horizontal, 10).frame(height: 36)
    }
}

private struct ConnectingView: View {
    let step: ConnectStep
    let email: String
    let cancel: () -> Void
    @State private var spinning = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(.primary.opacity(0.08), lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.22)
                    .stroke(.primary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                Image(nsImage: MenuBarIcon.snowflake(size: 24, lineWidth: 1.5)).renderingMode(.template)
                    .foregroundStyle(.primary)
            }
            .frame(width: 56, height: 56)
            .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spinning = true } }
            .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("Connecting to TCL Home").font(.system(size: 15, weight: .semibold))
                if !email.isEmpty { Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }

            VStack(alignment: .leading, spacing: 0) {
                stepRow(.signingIn, "Signing in to your account")
                Divider().padding(.leading, 30)
                stepRow(.findingDevices, "Finding your air conditioners")
            }
            .padding(.horizontal, 12)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            Button("Cancel", action: cancel)
                .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 12)
        .animation(.snappy, value: step)
    }

    private func stepRow(_ row: ConnectStep, _ title: String) -> some View {
        let done = row.rawValue < step.rawValue, current = row == step
        return HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18).background(.primary.opacity(0.1), in: Circle())
                } else if current {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                } else {
                    Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1).frame(width: 14, height: 14)
                }
            }
            .frame(width: 18, height: 18)
            Text(title).font(.callout).foregroundStyle(done || current ? .primary : .secondary)
            Spacer()
        }
        .frame(height: 38)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : current ? "In progress" : "Waiting")
    }
}

private struct DeviceCard: View {
    @ObservedObject var energyStore: AppStore
    @State private var showEnergy = false
    @State private var showControls = false
    let device: AirConditioner
    /// False when the unit switcher above already names this unit; the status becomes the heading instead.
    let showsName: Bool
    let pending: Bool
    let unconfirmed: Bool
    /// Changes show instantly (the store predicts the result), so controls stay live while the cloud confirms.
    let send: (ACCommand) -> Void
    private var enabled: Bool { device.isOnline && device.isSupported }
    private var active: Bool { device.isOnline && device.statusMessage == nil && device.power }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    if showsName {
                        Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(statusHeading).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let statusDetail {
                            Text(statusDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                }
                // The heading glides to and from center as the sync line comes and goes, instead of jumping.
                .animation(.easeInOut(duration: 0.25), value: statusDetail)
                Spacer(minLength: 4)
                powerButton
            }
            .frame(minHeight: 32) // Room for a second line, so "Syncing…" appearing doesn't resize the panel.
            ACHero(running: active, speed: airflowSpeed, unitID: device.id,
                   vertical: device.airflow(.vertical), horizontal: device.airflow(.horizontal),
                   // The display follows the slider while dragging, not just the confirmed target.
                   readout: device.isOnline ? (draftTemperature ?? device.targetTemperature).map { String(format: "%.0f", $0) } : nil,
                   mode: device.isOnline ? device.mode : nil)
            if !device.isOnline {
                // Last-known values would be stale, so show none of them.
                Label("Offline. Check the unit's power and Wi-Fi.", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if device.isSupported, let target = device.targetTemperature {
                temperatureControl(target)
            } else if let message = unsupportedMessage {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if device.isOnline && device.isSupported {
                presetRow
            }
            if device.isOnline && device.isSupported && device.hasExtraControls {
                controlTiles
            }
            if device.isOnline && device.isSupported {
                VStack(alignment: .leading, spacing: 0) {
                    if device.isSupported && hasMoreControls {
                        sectionHeader("More", id: "more-\(device.id)", summary: nil, expanded: showControls) { showControls.toggle() }
                        if showControls { moreControls.padding(.bottom, 10).transition(.opacity) }
                    }
                    if device.isSupported && device.isOnline {
                        if hasMoreControls { Divider() }
                        sectionHeader("Electricity", id: "electricity-\(device.id)", summary: showEnergy ? nil : energySummary, expanded: showEnergy) {
                            showEnergy.toggle()
                            if showEnergy, energyStore.energyReports[device.id] == nil {
                                Task { await energyStore.loadEnergy(for: device) }
                            }
                        }
                        if showEnergy { energyContent.padding(.bottom, 4).transition(.opacity) }
                    }
                }
                .padding(.top, -4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .animation(.snappy, value: device.targetTemperature)
    }

    @State private var draftTemperature: Double?

    private var airflowSpeed: Double {
        switch device.fanSpeed {
        case .quiet, .low, .speed1: return 0.6
        case .mediumLow: return 0.8
        case .mediumHigh, .high: return 1.3
        case .turbo: return 1.7
        default: return 1
        }
    }

    private func temperatureControl(_ target: Double) -> some View {
        let shown = draftTemperature ?? target
        let canAdjust = enabled && device.power
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(shown, specifier: "%.0f")")
                    .font(.system(size: 40, weight: .light)).monospacedDigit()
                    .contentTransition(.numericText(value: shown))
                Text("°C").font(.system(size: 16)).foregroundStyle(.secondary)
                Spacer()
                // The outdoor unit only reports while the AC runs; when off, its last reading is stale, so hide it.
                let outdoor = device.power ? device.outdoorTemperature : nil
                if device.currentTemperature != nil || outdoor != nil {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let room = device.currentTemperature {
                            Label("\(room.formatted(.number.precision(.fractionLength(0))))°C indoors", systemImage: "thermometer.medium")
                                .help("Current indoor temperature")
                        }
                        if let outdoor {
                            Label("\(outdoor.formatted(.number.precision(.fractionLength(0))))°C outdoors", systemImage: "sun.max")
                                .help("Outdoor unit temperature")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Target \(shown, specifier: "%.0f") degrees")
            HStack(spacing: 10) {
                stepButton("minus", label: "Lower temperature", value: target - 1)
                // The track is the only thing in this column, so it centers on the −/+ buttons; the end labels hang below it.
                Slider(value: Binding(get: { shown }, set: { draftTemperature = $0.rounded() }),
                       in: device.minTemperature...device.maxTemperature) { editing in
                    if !editing, let value = draftTemperature {
                        if value != target { send(.temperature(value)) }
                        draftTemperature = nil
                    }
                }
                .controlSize(.small)
                .tint(.primary)
                .accessibilityLabel("Target temperature for \(device.name)")
                .overlay(alignment: .bottom) {
                    HStack {
                        Text("\(device.minTemperature, specifier: "%.0f")°")
                        Spacer()
                        Text("\(device.maxTemperature, specifier: "%.0f")°")
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                    .offset(y: 16)
                    .allowsHitTesting(false)
                }
                stepButton("plus", label: "Raise temperature", value: target + 1)
            }
            .padding(.bottom, 10) // room for the end labels hanging under the track
            .disabled(!canAdjust)
        }
        .opacity(device.power ? 1 : 0.4)
    }

    @Environment(\.scrollToSection) private var scrollToSection

    private func sectionHeader(_ title: String, id: String, summary: String?, expanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { toggle() }
            // Opening a section: wait one layout pass, then bring it to the top of the panel.
            if !expanded {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    scrollToSection(id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.callout)
                Spacer()
                if let summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityLabel("\(expanded ? "Hide" : "Show") \(title.lowercased())")
    }

    private var energySummary: String? {
        guard let today = energyStore.energyReports[device.id]?.todayKWh else { return nil }
        return "Today \(today.formatted(.number.precision(.fractionLength(2)))) kWh"
    }

    private var energyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = energyStore.energyReports[device.id] {
                if let message = report.message {
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 12) {
                        energyTile("Today", value: report.todayKWh, emphasized: true)
                        energyTile("Yesterday", value: report.yesterdayKWh)
                        energyTile("7 days", value: report.weekKWh)
                    }
                    EnergyChart(report: report)
                }
            }
            if let error = energyStore.energyErrors[device.id] {
                Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 6) {
                if energyStore.pendingEnergy.contains(device.id) {
                    ProgressView().controlSize(.mini)
                    Text("Updating…")
                } else if let report = energyStore.energyReports[device.id] {
                    Text("Updated \(report.fetchedAt.formatted(date: .omitted, time: .shortened))")
                }
                Spacer()
                Button { Task { await energyStore.loadEnergy(for: device) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        .frame(height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(energyStore.pendingEnergy.contains(device.id))
                .help("Refresh electricity")
                .accessibilityLabel("Refresh electricity for \(device.name)")
            }
            .foregroundStyle(.tertiary)
        }.font(.caption)
    }

    private func energyTile(_ title: String, value: Double?, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { $0.formatted(.number.precision(.fractionLength($0 < 100 ? 2 : 1))) } ?? "—")
                    .font(.system(size: 15, weight: emphasized ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                if value != nil { Text("kWh").foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.map { "\($0.formatted(.number.precision(.fractionLength(2)))) kilowatt hours" } ?? "no reading")")
    }

    private var statusText: String {
        guard device.isOnline else { return "Offline" }
        if unconfirmed { return "Not confirmed yet · refresh to check" }
        guard device.statusMessage == nil else { return "State unavailable" }
        let power = device.power ? "On" : "Off"
        return pending ? "\(power) · Syncing…" : power
    }

    /// Heading when the switcher names the unit: power and mode, e.g. "On · Cool".
    private var statusHeading: String {
        guard device.isOnline else { return "Offline" }
        guard device.statusMessage == nil else { return "State unavailable" }
        guard device.power else { return "Off" }
        return device.mode.map { "On · \($0.title)" } ?? "On"
    }

    /// Transient sync state shown under the heading.
    private var statusDetail: String? {
        guard device.isOnline else { return nil }
        if unconfirmed { return "Not confirmed yet · refresh to check" }
        return pending ? "Syncing…" : nil
    }

    private var controlsEnabled: Bool { enabled && device.power }

    /// Presets and the sleep timer. The timer shows a live countdown while it runs.
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Preset.allCases) { preset in
                    Button { Haptic.tap(); energyStore.apply(preset, to: device) } label: {
                        Label(preset.title, systemImage: preset.symbol)
                            .font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.title) for \(device.name)")
                }
                timerMenu
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            if let timer = energyStore.sleepTimer, timer.deviceID == device.id {
                HStack(spacing: 6) {
                    Image(systemName: "timer").foregroundStyle(.secondary)
                    Text("Turns off in").foregroundStyle(.secondary)
                    Text(timer.ends, style: .timer).monospacedDigit()
                    Spacer()
                    Button("Cancel") { energyStore.cancelSleepTimer() }.buttonStyle(.borderless)
                }
                .font(.caption)
            }
        }
    }

    private var timerMenu: some View {
        Menu {
            ForEach([15, 30, 60, 120], id: \.self) { minutes in
                Button(minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes > 60 ? "s" : "")") {
                    energyStore.startSleepTimer(minutes: minutes, for: device)
                }
            }
            if energyStore.sleepTimer?.deviceID == device.id {
                Divider()
                Button("Cancel Timer", role: .destructive) { energyStore.cancelSleepTimer() }
            }
        } label: {
            Label("Timer", systemImage: "timer")
                .font(.caption.weight(.medium)).labelStyle(.iconOnly)
                .frame(width: 34, height: 26)
                .background(.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
        .accessibilityLabel("Sleep timer for \(device.name)")
        .help("Turn off after…")
    }

    private var hasMoreControls: Bool {
        ACFeature.allCases.contains { device.feature($0) != nil }
    }

    private enum ControlPanel { case mode, fan, sleep, airflow }
    @State private var openPanel: ControlPanel?

    /// Mode, fan, sleep and airflow as tiles. Tapping one opens its options as chips right below, inside the card.
    private var controlTiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !device.modes.isEmpty {
                    tile(.mode, "Mode", symbol: device.mode?.symbol ?? "a.circle", lines: [TileLine(icon: nil, text: device.mode?.title ?? "—")])
                }
                if !device.fanSpeeds.isEmpty {
                    tile(.fan, "Fan", symbol: "fan", lines: [TileLine(icon: nil, text: device.fanSpeed?.title ?? "Custom")])
                        .disabled(device.mode == .dry)
                }
                if let sleep = device.sleep {
                    tile(.sleep, "Sleep", symbol: "moon", lines: [TileLine(icon: nil, text: sleep.title)])
                        .disabled(device.mode != .cool && device.mode != .heat && sleep == .off)
                }
                if !airflowAxes.isEmpty {
                    tile(.airflow, "Airflow", symbol: "wind", lines: [TileLine(icon: nil, text: airflowSummary)])
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let panel = openPanel {
                chooser(panel)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
            }
        }
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.4)
        .onChange(of: controlsEnabled) { _, enabled in if !enabled { openPanel = nil } }
    }

    /// One line for the Airflow tile, so it matches the other tiles; the menu has each axis.
    private var airflowSummary: String {
        let values = airflowAxes.map { device.airflow($0) }
        if values.allSatisfy({ $0 == .swing }) { return "Swing" }
        if values.allSatisfy({ $0 == .stop }) { return "Fixed" }
        if airflowAxes.count == 1, let axis = airflowAxes.first { return device.airflow(axis)?.title(for: axis) ?? "Custom" }
        if device.airflow(.vertical) == .swing { return "Up / down" }
        if device.airflow(.horizontal) == .swing { return "Side to side" }
        return device.airflow(.vertical)?.title(for: .vertical) ?? "Custom"
    }

    private var airflowAxes: [ACAxis] { ACAxis.allCases.filter(device.supportsAirflow) }

    private func tile(_ panel: ControlPanel, _ title: String, symbol: String, lines: [TileLine]) -> some View {
        OptionTile(title: title, symbol: symbol, lines: lines, isOpen: openPanel == panel) {
            withAnimation(.snappy) { openPanel = openPanel == panel ? nil : panel }
        }
    }

    @ViewBuilder private func chooser(_ panel: ControlPanel) -> some View {
        switch panel {
        case .mode:
            // Five modes fit one row as equal-width tiles with the icon above the label.
            HStack(spacing: 6) {
                ForEach(device.modes) { mode in
                    let selected = device.mode == mode
                    Button { choose { send(.mode(mode)) } } label: {
                        VStack(spacing: 3) {
                            Image(systemName: mode.symbol).font(.system(size: 14))
                            Text(mode.title).font(.caption2.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                        .background(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.07)), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.title) mode")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        case .fan:
            FlowLayout { ForEach(device.fanSpeeds) { speed in
                OptionChip(title: speed.title, symbol: nil, selected: device.fanSpeed == speed) { choose { send(.fan(speed)) } }
            } }
        case .sleep:
            FlowLayout { ForEach(ACSleep.allCases) { sleep in
                OptionChip(title: sleep.title, symbol: nil, selected: device.sleep == sleep) { choose { send(.sleep(sleep)) } }
            } }
        case .airflow:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(airflowAxes) { axis in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(axis.title).font(.caption).foregroundStyle(.secondary)
                        FlowLayout { ForEach(ACAirflow.allCases) { airflow in
                            // Two axes live here, so the panel stays open after a choice.
                            OptionChip(title: airflow.title(for: axis), symbol: nil, selected: device.airflow(axis) == airflow) {
                                Haptic.tap(); send(.airflow(axis, airflow))
                            }
                        } }
                    }
                }
            }
        }
    }

    /// Applies a single-choice option and closes its panel.
    private func choose(_ action: () -> Void) {
        Haptic.tap()
        action()
        withAnimation(.snappy) { openPanel = nil }
    }

    private var moreControls: some View {
        settingsGroup {
            ForEach(ACFeature.allCases) { option in
                if let value = device.feature(option) {
                    settingRow(option.title, option.symbol) {
                        Toggle(option.title, isOn: Binding(get: { value }, set: { send(.feature(option, $0)) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    .disabled(option == .eco && !value && device.mode != .cool)
                }
            }
        }
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.4)
    }

    private func settingsGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func settingRow<Control: View>(_ title: String, _ symbol: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
            Spacer(minLength: 8)
            control()
        }
        .font(.callout)
        .frame(minHeight: 30)
    }

    private var unsupportedMessage: String? {
        if !device.isSupported { return device.statusMessage ?? "Controls for this model aren't supported yet." }
        return "This unit doesn't report a target temperature."
    }

    private var powerButton: some View {
        Button {
            Haptic.tap()
            send(.power(!device.power))
        } label: {
            Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(active ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                .background(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.08)), in: Circle())
                .animation(.snappy, value: active)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(device.power ? "Turn Off" : "Turn On")
        .accessibilityLabel(device.power ? "Turn off \(device.name)" : "Turn on \(device.name)")
        .accessibilityValue(pending ? "Updating" : "")
    }

    private func stepButton(_ symbol: String, label: String, value: Double) -> some View {
        let allowed = enabled && device.power && value >= device.minTemperature && value <= device.maxTemperature
        return Button { Haptic.tap(); send(.temperature(value)) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!allowed)
        .foregroundStyle(allowed ? Color.primary : Color.secondary.opacity(0.5))
        .accessibilityLabel("\(label) for \(device.name)")
    }
}

private extension ACAirflow {
    /// Fixed position, 0 (Top / Left) … 4 (Bottom / Right); nil for swing and stop.
    var position: Double? { rawValue >= 9 ? Double(rawValue - 9) : nil }
}

private extension ACMode {
    var symbol: String {
        switch self {
        case .auto: return "a.circle"
        case .cool: return "snowflake"
        case .dry: return "drop"
        case .fan: return "fan"
        case .heat: return "sun.max"
        }
    }
}

private extension ACFeature {
    var symbol: String {
        switch self {
        case .eco: return "leaf"
        case .health: return "heart"
        case .display: return "lightbulb"
        case .beep: return "speaker.wave.2"
        }
    }
}


private struct EnergyChart: View {
    let report: EnergyReport

    private struct Bar: Identifiable {
        let id: String
        let label: String
        let kWh: Double?
        let isToday: Bool
    }

    /// One bar per day in the window, so missing days show as gaps rather than zeros.
    private var bars: [Bar] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let start = parser.date(from: report.start) else { return [] }
        let calendar = Calendar.current
        let values = Dictionary(report.days.map { ($0.date, $0.kWh) }, uniquingKeysWith: { $1 })
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = parser.string(from: date)
            return Bar(id: key, label: date.formatted(.dateTime.weekday(.narrow)), kWh: values[key], isToday: key == report.today)
        }
    }

    var body: some View {
        let bars = bars
        let peak = max(bars.compactMap(\.kWh).max() ?? 0, 0.01)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(bars) { bar in
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(bar.isToday ? Color.primary : Color.primary.opacity(0.25))
                                .frame(height: bar.kWh.map { max(2, proxy.size.height * $0 / peak) } ?? 0)
                        }
                    }
                    Text(bar.label)
                        .foregroundStyle(bar.isToday ? .primary : .secondary)
                        .fontWeight(bar.isToday ? .semibold : .regular)
                }
                .frame(maxWidth: .infinity)
                .help(bar.kWh.map { "\(bar.id): \($0.formatted(.number.precision(.fractionLength(2)))) kWh" } ?? "\(bar.id): no reading")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(bar.id)
                .accessibilityValue(bar.kWh.map { "\($0.formatted(.number.precision(.fractionLength(2)))) kilowatt hours" } ?? "No reading")
            }
        }
        .frame(height: 64)
        .animation(.snappy, value: report.fetchedAt)
    }
}


/// Equal-width unit picker shown when the account has more than one AC.
private struct DeviceSwitcher: View {
    let devices: [AirConditioner]
    @Binding var selection: String

    var body: some View {
        let current = devices.first { $0.id == selection }?.id ?? devices.first?.id
        HStack(spacing: 2) {
            ForEach(devices) { device in
                let selected = device.id == current
                Button { withAnimation(.easeInOut(duration: 0.2)) { selection = device.id } } label: {
                    HStack(spacing: 5) {
                        Circle().fill(device.isOnline && device.power ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 5, height: 5)
                        Text(device.name).lineLimit(1).minimumScaleFactor(0.8)
                        if !device.isOnline { Image(systemName: "wifi.slash").font(.system(size: 9)) }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(!device.isOnline ? .tertiary : selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(device.name)
                .accessibilityLabel(device.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// A compact tile that opens a native menu of options.
struct TileLine {
    let icon: String?
    let text: String
}

/// A control tile that opens its options inline instead of a pop-up menu.
private struct OptionTile: View {
    let title: String
    let symbol: String
    let lines: [TileLine]
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 14))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.caption2).foregroundStyle(.secondary)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 3) {
                            if let icon = line.icon {
                                Image(systemName: icon).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            Text(line.text).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.primary.opacity(isOpen ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(isOpen ? 0.25 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(lines.map(\.text).joined(separator: ", "))")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityHint(isOpen ? "Hides the options" : "Shows the options")
    }
}

/// One selectable option inside an opened tile; the current choice is filled.
private struct OptionChip: View {
    let title: String
    let symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.07)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays chips out left to right and wraps to the next line when a row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Thin arc that orbits the power button while a command is in flight.
/// A light trackpad tap on controls that change the AC. No-op without a Force Touch trackpad.
private enum Haptic {
    static func tap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
}

/// Vector indoor unit with a louver, display and airflow. Powering on opens the louver,
/// lights the display and builds the airflow over about a second; powering off reverses it.
/// The airflow follows the mode: cool particles, wavy warm air, slower dry air.
private struct ACHero: View {
    let running: Bool
    var speed: Double = 1
    /// Remembers where this unit's flap and fins were left, across stops and reopening the panel.
    var unitID = ""
    /// Up/down setting: swing rocks the flap, a position sets its angle, stop holds it where it is.
    var vertical: ACAirflow?
    /// Left/right setting: the same for the fins (and the airflow's lean).
    var horizontal: ACAirflow?
    var readout: String?
    var mode: ACMode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var changedAt = Date.distantPast
    @State private var transitioning = false
    @State private var flap = LouverMotion(wave: .tilt, value: 1)
    @State private var fins = LouverMotion(wave: .side, value: 0)
    @State private var restored = false
    private static var lastPositions: [String: (flap: Double, fins: Double)] = [:]

    private static let ramp = 1.1
    private static let streams = 11
    private static let wispsPerStream = 3

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || (!running && !transitioning))) { context in
            Canvas { canvas, size in draw(&canvas, size: size, now: context.date) } symbols: {
                Image(systemName: mode?.symbol ?? "a.circle")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .tag("mode")
            }
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .onChange(of: running) { _, _ in
            changedAt = .now
            transitioning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.ramp + 0.1) { transitioning = false }
        }
        .onAppear {
            guard !restored else { return }
            restored = true
            let last = Self.lastPositions[unitID]
            flap = LouverMotion(wave: .tilt, value: last?.flap ?? 1)
            fins = LouverMotion(wave: .side, value: last?.fins ?? 0)
            flap.apply(vertical.map(Self.tilt), at: .now)
            fins.apply(horizontal.map(Self.side), at: .now)
        }
        .onChange(of: vertical) { _, new in flap.apply(new.map(Self.tilt), at: .now); remember() }
        .onChange(of: horizontal) { _, new in fins.apply(new.map(Self.side), at: .now); remember() }
        .onDisappear { remember() }
    }

    private func remember() {
        let now = Date()
        Self.lastPositions[unitID] = (flap.value(at: now, still: reduceMotion), fins.value(at: now, still: reduceMotion))
    }

    /// Up/down target: swing, a position (0 = Top … 1 = Bottom), or hold for stop.
    private static func tilt(_ airflow: ACAirflow) -> LouverMotion.Target {
        airflow == .swing ? .swing : airflow.position.map { .position($0 / 4) } ?? .hold
    }

    /// Left/right target: swing, a position (−1 = Left … 1 = Right), or hold for stop.
    private static func side(_ airflow: ACAirflow) -> LouverMotion.Target {
        airflow == .swing ? .swing : airflow.position.map { .position(($0 - 2) / 2) } ?? .hold
    }

    /// Where the fins point, −1 (left) … 1 (right).
    private func finSide(_ now: Date) -> Double { fins.value(at: now, still: reduceMotion) }

    private func draw(_ canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let raw = reduceMotion ? 1 : min(1, now.timeIntervalSince(changedAt) / Self.ramp)
        let eased = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2
        let level = running ? eased : 1 - eased            // 0 = off, 1 = fully running
        let time = reduceMotion ? 0.6 : now.timeIntervalSinceReferenceDate
        let ink = Color.primary
        let dark = colorScheme == .dark
        let recess = Color.black.opacity(dark ? 0.42 : 0.16)

        let width = min(size.width * 0.64, 236), height: CGFloat = 68
        let unit = CGRect(x: (size.width - width) / 2, y: 4, width: width, height: height)
        let shell = Path(roundedRect: unit, cornerRadius: 6, style: .continuous)
        let seamY = unit.maxY - 24

        // Body: vertical shading, a darker lower panel below the seam, and a soft diagonal gloss.
        canvas.fill(shell, with: .linearGradient(Gradient(colors: [ink.opacity(0.12), ink.opacity(0.04)]),
                                                 startPoint: CGPoint(x: unit.midX, y: unit.minY), endPoint: CGPoint(x: unit.midX, y: unit.maxY)))
        canvas.drawLayer { layer in
            layer.clip(to: shell)
            layer.fill(Path(CGRect(x: unit.minX, y: seamY, width: width, height: unit.maxY - seamY)), with: .color(.black.opacity(dark ? 0.12 : 0.04)))
            var gloss = Path()
            gloss.move(to: CGPoint(x: unit.minX + width * 0.08, y: unit.minY))
            gloss.addLine(to: CGPoint(x: unit.minX + width * 0.30, y: unit.minY))
            gloss.addLine(to: CGPoint(x: unit.minX + width * 0.18, y: seamY))
            gloss.addLine(to: CGPoint(x: unit.minX - width * 0.04, y: seamY))
            gloss.closeSubpath()
            layer.drawLayer { soft in
                soft.addFilter(.blur(radius: 6))
                soft.fill(gloss, with: .linearGradient(Gradient(colors: [ink.opacity(0.06), ink.opacity(0)]),
                                                       startPoint: CGPoint(x: unit.minX, y: unit.minY), endPoint: CGPoint(x: unit.minX + width * 0.3, y: seamY)))
            }
            var seam = Path()
            seam.move(to: CGPoint(x: unit.minX, y: seamY))
            seam.addLine(to: CGPoint(x: unit.maxX, y: seamY))
            layer.stroke(seam, with: .color(ink.opacity(0.10)), lineWidth: 1)
        }
        canvas.stroke(shell, with: .color(ink.opacity(0.22 + 0.22 * level)), lineWidth: 1)
        var highlight = Path()
        highlight.move(to: CGPoint(x: unit.minX + 7, y: unit.minY + 1.5))
        highlight.addLine(to: CGPoint(x: unit.maxX - 7, y: unit.minY + 1.5))
        canvas.stroke(highlight, with: .color(ink.opacity(0.14)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Display window: mode icon and target temperature, lit while running.
        let display = CGRect(x: unit.maxX - 60, y: unit.minY + 14, width: 42, height: 16)
        canvas.fill(Path(roundedRect: display, cornerRadius: 4, style: .continuous), with: .color(recess.opacity(0.6 + 0.4 * level)))
        var lit = canvas
        lit.opacity = 0.9 * level                          // blank when off
        if let symbol = canvas.resolveSymbol(id: "mode") { lit.draw(symbol, at: CGPoint(x: display.minX + 10.5, y: display.midY)) }
        if let readout {
            lit.draw(Text(readout).font(.system(size: 9.5, weight: .semibold).monospacedDigit()).foregroundStyle(ink),
                     at: CGPoint(x: display.maxX - 13.5, y: display.midY))
        }

        // Outlet and louver. The flap is hinged along the outlet's bottom edge. Closed, it stands flush over the outlet;
        // opening, it rotates out and down, so seen from the front its free edge drops past the hinge and swings toward
        // the viewer (a touch wider, more bowed), uncovering the dark outlet and its vertical fins.
        let outlet = CGRect(x: unit.minX + 16, y: seamY + 6, width: width - 32, height: 11)
        let left = outlet.minX, right = outlet.maxX
        // Up/down swing rocks the open flap between Top (95°) and Bottom (155°, hanging below the unit); otherwise it holds its set position.
        let tilt = flap.value(at: now, still: reduceMotion)
        let angle = level * (95 + 60 * tilt) * .pi / 180            // 0 = closed (upright), past 90° = tilted down
        let hingeY = outlet.maxY
        let freeY = hingeY - outlet.height * cos(angle)             // projected free edge
        let spread = 3 * sin(angle)                                 // nearer the viewer, so it reads slightly wider
        let bow = 2.5 * sin(angle)
        let flapBottom = max(freeY, hingeY)

        if level > 0.01 {
            let opening = CGRect(x: left, y: outlet.minY, width: outlet.width, height: max(min(freeY, hingeY) - outlet.minY, 0))
            // Recess, darkest at the back (top), so the vanes read as sitting inside it.
            canvas.fill(Path(roundedRect: opening, cornerRadius: 1.5), with: .linearGradient(
                Gradient(colors: [recess.opacity(1), recess.opacity(0.75)]),
                startPoint: CGPoint(x: 0, y: opening.minY), endPoint: CGPoint(x: 0, y: opening.maxY)))
            // Vanes: each pivots on its fixed back edge, its front edge swinging left or right. Edge-on (center) they're
            // thin lines; turned, their faces show as narrow lit slabs. Always the same set in view.
            let turn = 4 * finSide(now) * level
            let top = opening.minY + 1, bottom = max(opening.maxY - 0.5, opening.minY + 1)
            var faces = Path(), fronts = Path(), backs = Path()
            var x = left + 8
            while x <= right - 8 {
                faces.move(to: CGPoint(x: x, y: top))
                faces.addLine(to: CGPoint(x: x + turn, y: top))
                faces.addLine(to: CGPoint(x: x + turn, y: bottom))
                faces.addLine(to: CGPoint(x: x, y: bottom))
                faces.closeSubpath()
                fronts.move(to: CGPoint(x: x + turn, y: top)); fronts.addLine(to: CGPoint(x: x + turn, y: bottom))
                backs.move(to: CGPoint(x: x, y: top)); backs.addLine(to: CGPoint(x: x, y: bottom))
                x += 9
            }
            let facing = abs(turn) / 4
            canvas.fill(faces, with: .linearGradient(Gradient(colors: [ink.opacity(0.04 * level), ink.opacity((0.06 + 0.10 * facing) * level)]),
                                                     startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bottom)))
            canvas.stroke(backs, with: .color(ink.opacity(0.08 * level)), lineWidth: 0.75)
            canvas.stroke(fronts, with: .linearGradient(Gradient(colors: [ink.opacity(0.10 * level), ink.opacity(0.30 * level)]),
                                                        startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bottom)),
                          style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }

        var flap = Path()
        flap.move(to: CGPoint(x: left, y: hingeY))
        flap.addLine(to: CGPoint(x: right, y: hingeY))
        flap.addLine(to: CGPoint(x: right + spread, y: freeY))
        flap.addQuadCurve(to: CGPoint(x: left - spread, y: freeY), control: CGPoint(x: (left + right) / 2, y: freeY + bow))
        flap.closeSubpath()
        if level > 0.01 {
            // The open flap is translucent, so knock out what's behind it first; otherwise the body's bottom outline shows through.
            var behind = canvas
            behind.blendMode = .destinationOut
            behind.fill(flap, with: .color(.black.opacity(level)))
        }
        let open = max(sin(angle), 0) * level                      // how much of the flap's face and edge we see
        if open > 0.01 {
            // Soft shadow the flap casts just below its edge.
            canvas.drawLayer { shade in
                shade.addFilter(.blur(radius: 2.5))
                var under = Path()
                under.move(to: CGPoint(x: right + spread, y: freeY + 1))
                under.addQuadCurve(to: CGPoint(x: left - spread, y: freeY + 1), control: CGPoint(x: (left + right) / 2, y: freeY + bow + 1))
                shade.stroke(under, with: .color(.black.opacity(0.35 * open)), lineWidth: 3)
            }
        }
        // Face: shaded near the hinge, catching light toward the free edge, more so as it turns toward the viewer.
        canvas.fill(flap, with: .linearGradient(Gradient(colors: [ink.opacity(0.06), ink.opacity(0.07 + 0.10 * open)]),
                                                startPoint: CGPoint(x: 0, y: hingeY), endPoint: CGPoint(x: 0, y: freeY)))
        if open > 0.01 {
            // Contact shadow along the hinge, where the flap meets the outlet.
            var hinge = Path()
            hinge.move(to: CGPoint(x: left + 1, y: hingeY)); hinge.addLine(to: CGPoint(x: right - 1, y: hingeY))
            canvas.stroke(hinge, with: .color(.black.opacity(0.35 * open)), lineWidth: 1)
            // Edge thickness: a thin band under the free edge, curved with it.
            let thickness = 1.8 * open
            var edge = Path()
            edge.move(to: CGPoint(x: right + spread, y: freeY))
            edge.addQuadCurve(to: CGPoint(x: left - spread, y: freeY), control: CGPoint(x: (left + right) / 2, y: freeY + bow))
            edge.addLine(to: CGPoint(x: left - spread + 0.5, y: freeY + thickness))
            edge.addQuadCurve(to: CGPoint(x: right + spread - 0.5, y: freeY + thickness),
                              control: CGPoint(x: (left + right) / 2, y: freeY + bow + thickness))
            edge.closeSubpath()
            canvas.fill(edge, with: .color(ink.opacity(0.10 * open)))
        }
        if level < 0.99 {
            // Closed seam around the flap, fading out as it opens.
            canvas.stroke(Path(roundedRect: CGRect(x: left, y: min(freeY, hingeY), width: right - left, height: max(abs(freeY - hingeY), 1)), cornerRadius: 1.5),
                          with: .color(ink.opacity(0.14 * (1 - level))), lineWidth: 1)
        }
        var lip = Path()
        lip.move(to: CGPoint(x: right + spread, y: freeY))
        lip.addQuadCurve(to: CGPoint(x: left - spread, y: freeY), control: CGPoint(x: (left + right) / 2, y: freeY + bow))
        // Front edge catching the light.
        canvas.stroke(lip, with: .color(ink.opacity(0.15 + 0.45 * level)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        guard level > 0.01 else { return }
        let top = flapBottom + bow + 3.5, depth = size.height - top - 2
        let sweep = finSide(now) * 0.35                              // in step with the fins
        let pace = speed * (mode == .dry ? 0.6 : 1)
        let waviness: Double = mode == .heat ? 7 : 3.5
        let strength: Double = mode == .dry ? 0.7 : mode == .fan ? 0.85 : 1

        // Soft glow of moving air beneath the vent.
        var cone = Path()
        cone.move(to: CGPoint(x: left + 4, y: top))
        cone.addLine(to: CGPoint(x: right - 4, y: top))
        cone.addLine(to: CGPoint(x: unit.midX + width * 0.64 + sweep * depth * 1.4, y: top + depth))
        cone.addLine(to: CGPoint(x: unit.midX - width * 0.64 + sweep * depth * 1.4, y: top + depth))
        cone.closeSubpath()
        canvas.drawLayer { glow in
            glow.addFilter(.blur(radius: 12))
            glow.fill(cone, with: .linearGradient(Gradient(colors: [ink.opacity(0.10 * level * strength), ink.opacity(0)]),
                                                  startPoint: CGPoint(x: unit.midX, y: top), endPoint: CGPoint(x: unit.midX, y: top + depth * 0.9)))
        }

        func point(_ t: Double, _ p: Double, _ seed: Double) -> CGPoint {
            let spread = t * (width / 2 - 22) + t * (p * 0.6 + p * p * 0.4) * width * 0.32
            let lean = sweep * p * depth * 1.4
            let sway = sin(time * (mode == .heat ? 2.6 : 1.6) + seed * 2.3 + p * (mode == .heat ? 7 : 4)) * waviness * p
            return CGPoint(x: unit.midX + spread + lean + sway, y: top + p * depth)
        }
        let reach = 0.35 + 0.65 * level                       // airflow extends further as it builds
        canvas.drawLayer { air in
        air.addFilter(.blur(radius: 0.7))
        for stream in 0..<Self.streams {
            let t = Double(stream) / Double(Self.streams - 1) * 2 - 1
            for wisp in 0..<Self.wispsPerStream {
                let seed = Double(stream * 7 + wisp * 13)
                let rate = 0.42 * pace * (0.85 + 0.3 * (sin(seed) * 0.5 + 0.5))
                let cycle = (time * rate + Double(wisp) / Double(Self.wispsPerStream) + sin(seed * 1.7) * 0.5)
                    .truncatingRemainder(dividingBy: 1)
                let head = cycle * reach, tail = max(0, head - 0.34 * reach)
                guard head > 0.02 else { continue }
                var path = Path()
                path.move(to: point(t, tail, seed))
                for step in 1...10 { path.addLine(to: point(t, tail + (head - tail) * Double(step) / 10, seed)) }
                let alpha = sin(.pi * cycle) * (0.42 - abs(t) * 0.12) * level * strength
                air.stroke(path, with: .linearGradient(Gradient(colors: [ink.opacity(0), ink.opacity(alpha), ink.opacity(alpha * 0.6)]),
                                                       startPoint: point(t, tail, seed), endPoint: point(t, head, seed)),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            // Cool air: small particles drifting between the wisps.
            if mode == .cool && stream % 2 == 1 {
                for particle in 0..<2 {
                    let seed = Double(stream * 11 + particle * 5 + 3)
                    let cycle = (time * 0.3 * pace * (0.8 + 0.4 * (sin(seed) * 0.5 + 0.5)) + Double(particle) * 0.5 + cos(seed) * 0.3)
                        .truncatingRemainder(dividingBy: 1)
                    let p = cycle * reach
                    let center = point(t + sin(seed) * 0.08, p, seed + 1)
                    let radius = 0.8 + 0.6 * (cos(seed * 2.1) * 0.5 + 0.5)
                    air.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(ink.opacity(sin(.pi * cycle) * 0.5 * level)))
                }
            }
        }
        }
    }
}
