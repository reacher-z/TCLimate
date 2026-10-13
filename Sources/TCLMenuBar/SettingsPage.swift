import SwiftUI
import AppKit
import TCLCore

/// Settings shown inside the panel (gear in the header) rather than in a dropdown menu.
struct SettingsPage: View {
    @ObservedObject var store: AppStore
    @ObservedObject var launchAtLogin: LaunchAtLogin
    let selectedDevice: AirConditioner?
    @AppStorage(MenuBarReading.storageKey) private var reading: MenuBarReading = .off
    @AppStorage(AppStore.offlineAlertsKey) private var offlineAlerts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Menu Bar") {
                caption("Show")
                tiles(MenuBarReading.allCases, selection: $reading, title: \.shortTitle) { reading in
                    if let image = reading.glyphImage { Image(nsImage: image).renderingMode(.template) }
                    else { Image(systemName: reading.symbol) }
                }
                if reading == .target || reading == .outdoor {
                    caption("Shows while the selected AC is on; otherwise the icon alone.")
                }
            }

            section("General") {
                group {
                    toggleRow("Launch at login", symbol: "power", isOn: Binding(
                        get: { launchAtLogin.isRequested }, set: { launchAtLogin.setEnabled($0) }))
                    if launchAtLogin.requiresApproval {
                        Button("Approve in Login Items…") { launchAtLogin.openSettings() }
                            .buttonStyle(.link).font(.caption).padding(.leading, 26).padding(.bottom, 6)
                    }
                    if store.connected {
                        Divider()
                        toggleRow("Notify when an AC goes offline", symbol: "bell", isOn: Binding(
                            get: { offlineAlerts }, set: { offlineAlerts = $0; store.setOfflineAlerts($0) }))
                    }
                }
            }

            if store.connected, store.devices.count > 1, let device = selectedDevice {
                section("All ACs") {
                    group {
                        actionRow("Turn off all", symbol: "power") { store.turnOffAll() }
                            .disabled(!store.devices.contains { $0.isOnline && $0.power })
                        Divider()
                        if device.isOnline && device.power {
                            actionRow("Copy settings from \(device.name)", symbol: "square.on.square") { store.copySettings(from: device) }
                        } else {
                            row(symbol: "square.on.square") {
                                Text("Turn on \(device.name) to copy its settings").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if store.connected {
                section("Account") {
                    group {
                        HStack(spacing: 10) {
                            AccountAvatar(url: store.profile?.avatarURL)
                            VStack(alignment: .leading, spacing: 1) {
                                if let name = store.profile?.nickname, !name.isEmpty {
                                    Text(name).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(store.email).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                } else {
                                    Text(store.email).font(.callout).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 8)
                            Button("Sign Out") { store.signOut() }
                                .disabled(store.busy || !store.pendingDevices.isEmpty)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }

            HStack {
                Text("TCLimate \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit TCLimate") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row<Content: View>(symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            content()
        }
        .font(.callout)
        .frame(minHeight: 34)
    }

    private func toggleRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        row(symbol: symbol) {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    private func actionRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            row(symbol: symbol) {
                Text(title)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Equal-width picker tiles; the selected one is filled, matching the mode tiles on the device card.
    private func tiles<Option: Identifiable & Hashable, Icon: View>(
        _ options: [Option], selection: Binding<Option>, title: KeyPath<Option, String>,
        @ViewBuilder icon: @escaping (Option) -> Icon
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(options) { option in
                let selected = selection.wrappedValue == option
                Button { selection.wrappedValue = option } label: {
                    VStack(spacing: 5) {
                        icon(option).font(.system(size: 14)).frame(height: 18)
                        Text(option[keyPath: title]).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                    .background(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.06)),
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option[keyPath: title])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// The account picture when TCL provides one, otherwise a person symbol.
private struct AccountAvatar: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Self.load(url)
        }
    }

    @MainActor private static var cache: [URL: NSImage] = [:]
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Loads without cookies or credentials, caps the size, and keeps the result for the session.
    @MainActor private static func load(_ url: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000,
              let image = NSImage(data: data) else { return nil }
        cache[url] = image
        return image
    }
}
