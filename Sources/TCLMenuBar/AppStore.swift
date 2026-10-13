import SwiftUI
import TCLCore
import UserNotifications

enum ConnectStep: Int { case signingIn = 1, findingDevices }

@MainActor
final class AppStore: ObservableObject {
    @Published var devices: [AirConditioner] = []
    @Published var energyReports: [String: EnergyReport] = [:]
    @Published var energyErrors: [String: String] = [:]
    @Published var pendingEnergy: Set<String> = []
    @Published var connected = false
    @Published var busy = false
    @Published var pendingDevices: Set<String> = []
    @Published var error: String?
    /// Devices whose last command was sent but not yet reflected in reported state.
    @Published var unconfirmedDevices: Set<String> = []
    @Published var lastUpdated: Date?
    @Published var profile: AccountProfile?
    /// Short, non-error note such as "Turning off 2 ACs". Cleared by the next action.
    @Published var notice: String?
    /// The one running sleep timer: turns `deviceID` off at `ends`.
    @Published var sleepTimer: SleepTimer?
    @Published var connectStep: ConnectStep?
    @Published var email = ""
    @Published var password = ""
    @Published var region: AccountRegion = .singapore
    @Published var remember = true
    private var client = CloudClient()
    private var generation = 0
    private var attemptedRestore = false
    private var commandChains: [String: Task<Void, Never>] = [:]
    private var commandSerial: [String: Int] = [:]
    /// Last state each unit actually reported, used to undo predictions that can't be confirmed.
    private var lastReported: [String: AirConditioner] = [:]
    private var sleepTask: Task<Void, Never>?
    private var backgroundRefresh: Task<Void, Never>?

    func restore() async {
        guard !attemptedRestore else { await refresh(); return }
        attemptedRestore = true
        do {
            guard let login = try LoginKeychain.load() else { return }
            email = login.email
            region = login.region
            await connect(login: login, save: false)
        } catch { self.error = error.localizedDescription }
    }

    func signIn() async {
        guard !busy, isValidEmail(email), !password.isEmpty else { return }
        let login = SavedLogin(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, region: region)
        await connect(login: login, save: remember)
    }

    private func connect(login: SavedLogin, save: Bool) async {
        busy = true
        error = nil
        unconfirmedDevices = []
        let current = generation
        let candidate = CloudClient()
        connectStep = .signingIn
        do {
            try await candidate.login(email: login.email, password: login.password, region: login.region)
            guard current == generation else { return }
            connectStep = .findingDevices
            let found = try await candidate.devices()
            guard current == generation else { return }
            client = candidate
            profile = await candidate.profile
            devices = found
            lastReported = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            startBackgroundRefresh()
            connected = true
            lastUpdated = Date()
            password = ""
            do {
                if save { try LoginKeychain.save(login) }
                else if !remember { try LoginKeychain.delete() }
            } catch { self.error = "Connected, but sign-in could not be saved. \(error.localizedDescription)" }
        } catch {
            if current == generation { self.error = error.localizedDescription }
        }
        if current == generation { busy = false; connectStep = nil }
    }

    func cancelConnect() {
        guard connectStep != nil else { return }
        generation += 1
        connectStep = nil
        busy = false
    }

    func refresh() async {
        guard connected, !busy else { return }
        busy = true
        let current = generation
        do {
            let found = try await client.devices()
            guard current == generation else { return }
            adopt(found, for: "")
            lastUpdated = Date()
            error = nil
            unconfirmedDevices = unconfirmedDevices.intersection(pendingDevices)
        } catch { if current == generation { self.error = error.localizedDescription } }
        if current == generation { busy = false }
    }

    /// Applies the command to the UI immediately, then sends and verifies it in the background.
    /// Commands for one unit go out in order; each builds on the displayed (predicted) state, so rapid taps accumulate.
    func send(_ command: ACCommand, to device: AirConditioner) {
        guard connected, device.isOnline, device.isSupported else { return }
        let id = device.id
        let base = devices.first { $0.id == id } ?? device
        let predicted: AirConditioner
        do { predicted = try base.applying(command) }
        catch { self.error = error.localizedDescription; return }
        replace(predicted)
        error = nil
        unconfirmedDevices.remove(id)
        pendingDevices.insert(id)
        let serial = (commandSerial[id] ?? 0) + 1
        commandSerial[id] = serial
        let previous = commandChains[id]
        let current = generation, activeClient = client
        commandChains[id] = Task { [weak self] in
            await previous?.value
            await self?.deliver(command, base: base, serial: serial, client: activeClient, generation: current)
        }
    }

    private func deliver(_ command: ACCommand, base: AirConditioner, serial: Int, client: CloudClient, generation current: Int) async {
        guard current == generation else { return }
        let id = base.id
        do { try await client.control(device: base, command: command) }
        catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
            // Put the unit back to what the cloud really reports.
            if let found = try? await client.devices() {
                guard current == generation else { return }
                adopt(found, for: id)
            } else if commandSerial[id] == serial {
                replace(lastReported[id] ?? base)   // can't reach the cloud either: undo the prediction
            }
            if commandSerial[id] == serial { finishPending(id) }
            return
        }
        // A newer command for this unit will do the verifying.
        guard commandSerial[id] == serial else { return }
        for delay in [2.0, 2.0, 3.0] {
            try? await Task.sleep(for: .seconds(delay))
            guard current == generation, commandSerial[id] == serial else { return }
            guard let found = try? await client.devices() else { continue }
            guard current == generation, commandSerial[id] == serial else { return }
            if found.first(where: { $0.id == id })?.confirms(command) == true {
                adopt(found, for: id)
                lastUpdated = Date()
                finishPending(id)
                return
            }
        }
        guard current == generation, commandSerial[id] == serial else { return }
        // Never confirmed: show what the cloud reports and say so.
        if let found = try? await client.devices(), current == generation, commandSerial[id] == serial { adopt(found, for: id) }
        unconfirmedDevices.insert(id)
        finishPending(id)
    }

    private func replace(_ device: AirConditioner) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
    }

    private func finishPending(_ id: String) {
        pendingDevices.remove(id)
        commandChains[id] = nil
    }

    /// Takes the cloud's list, but keeps the predicted state of any other unit with commands still in flight.
    /// Also where units going offline are noticed, so every fetch (not just one path) can raise the alert.
    private func adopt(_ found: [AirConditioner], for id: String) {
        let alerts = UserDefaults.standard.bool(forKey: Self.offlineAlertsKey)
        for reported in found {
            if alerts, !reported.isOnline, lastReported[reported.id]?.isOnline == true { postOfflineAlert(reported.name) }
            lastReported[reported.id] = reported
        }
        devices = found.map { reported in
            guard reported.id != id, pendingDevices.contains(reported.id),
                  let local = devices.first(where: { $0.id == reported.id }) else { return reported }
            return local
        }
    }

    // MARK: Actions across units

    func turnOffAll() {
        let on = devices.filter { $0.isOnline && $0.isSupported && $0.power }
        guard !on.isEmpty else { return }
        notice = on.count == 1 ? "Turning off \(on[0].name)" : "Turning off \(on.count) ACs"
        for device in on { send(.power(false), to: device) }
    }

    /// Copies mode, temperature, fan and airflow from `source` to the other units that are on.
    /// Each unit gets only the settings it supports and that fit its range.
    func copySettings(from source: AirConditioner) {
        let targets = devices.filter { $0.id != source.id && $0.isOnline && $0.isSupported && $0.power }
        let skipped = devices.filter { $0.id != source.id && !$0.power }.count
        guard !targets.isEmpty else { notice = "No other AC is on to copy to"; return }
        for target in targets {
            for command in Self.copyCommands(from: source, to: target) { send(command, to: target) }
        }
        var message = "Copied settings from \(source.name) to \(targets.count == 1 ? targets[0].name : "\(targets.count) ACs")"
        if skipped > 0 { message += " · \(skipped) off, skipped" }
        notice = message
    }

    static func copyCommands(from source: AirConditioner, to target: AirConditioner) -> [ACCommand] {
        var commands: [ACCommand] = []
        var current = target
        func add(_ command: ACCommand) {
            guard let next = try? current.applying(command) else { return }
            commands.append(command)
            current = next
        }
        if let mode = source.mode { add(.mode(mode)) }
        if let temperature = source.targetTemperature { add(.temperature(temperature)) }
        if let fan = source.fanSpeed, target.fanSpeeds.contains(fan) { add(.fan(fan)) }
        for axis in ACAxis.allCases {
            if let airflow = source.airflow(axis) { add(.airflow(axis, airflow)) }
        }
        return commands
    }

    /// Applies a preset to one unit, keeping only the steps that unit supports. Turns the unit on first if needed.
    func apply(_ preset: Preset, to device: AirConditioner) {
        for command in preset.commands(for: device) { send(command, to: device) }
    }

    // MARK: Sleep timer

    struct SleepTimer: Equatable {
        let deviceID: String
        let ends: Date
    }

    /// Turns the unit off after `minutes`. Runs only while the app is open; a new timer replaces the old one.
    func startSleepTimer(minutes: Int, for device: AirConditioner) {
        sleepTask?.cancel()
        let id = device.id
        let ends = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimer = SleepTimer(deviceID: id, ends: ends)
        sleepTask = Task { [weak self] in
            while Date() < ends {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.sleepTimer?.deviceID == id else { return }
            }
            guard let self, self.sleepTimer?.deviceID == id else { return }
            self.sleepTimer = nil
            if let unit = self.devices.first(where: { $0.id == id }), unit.power {
                self.notice = "\(unit.name) turned off by timer"
                self.send(.power(false), to: unit)
            }
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = nil
    }

    // MARK: Offline alerts

    /// Posts a notification when a unit goes offline. Off by default; detected by any refresh, including the
    /// background one.
    func setOfflineAlerts(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.offlineAlertsKey)
        guard enabled else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    static let offlineAlertsKey = "notifyWhenOffline"

    // MARK: Background refresh

    /// How often units refresh while the panel is closed, so the menu bar reading and offline alerts stay current.
    /// The open panel refreshes faster on its own.
    static let backgroundRefreshInterval: Duration = .seconds(120)

    private func startBackgroundRefresh() {
        backgroundRefresh?.cancel()
        let current = generation
        backgroundRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundRefreshInterval)
                guard !Task.isCancelled, let self, current == self.generation, self.connected else { return }
                // Skip when something else (the open panel's poll, a command) fetched recently.
                if let last = self.lastUpdated, Date().timeIntervalSince(last) < 60 { continue }
                await self.refresh()
            }
        }
    }

    private func postOfflineAlert(_ name: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(name) is offline"
        content.body = "TCLimate can't reach this AC. Check its power and Wi-Fi."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "offline-\(name)-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    func loadEnergy(for device: AirConditioner) async {
        guard connected, device.isOnline, !pendingEnergy.contains(device.id) else { return }
        let current = generation
        pendingEnergy.insert(device.id)
        energyErrors[device.id] = nil
        do {
            let report = try await client.energy(for: device)
            guard current == generation else { return }
            energyReports[device.id] = report
        } catch {
            if current == generation { energyErrors[device.id] = error.localizedDescription }
        }
        if current == generation { pendingEnergy.remove(device.id) }
    }

    func signOut() {
        guard !busy, pendingDevices.isEmpty else { return }
        do { try LoginKeychain.delete() }
        catch { self.error = error.localizedDescription; return }
        generation += 1
        client = CloudClient()
        commandChains = [:]
        commandSerial = [:]
        lastReported = [:]
        cancelSleepTimer()
        backgroundRefresh?.cancel()
        backgroundRefresh = nil
        notice = nil
        pendingDevices = []
        connected = false
        profile = nil
        devices = []
        energyReports = [:]
        energyErrors = [:]
        pendingEnergy = []
        password = ""
        lastUpdated = nil
        unconfirmedDevices = []
        error = nil
    }
}
