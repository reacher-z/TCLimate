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
    private var liveTask: Task<Void, Never>?
    /// True while MQTT is delivering updates, so polling can relax.
    private var liveConnected = false
    /// Latest state pushed for each unit since its last command.
    private var pushed: [String: AirConditioner] = [:]
    private var lastPolled: Date?
    private var onlineCheck: Task<Void, Never>?
    private var energyRefresh: Task<Void, Never>?

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
            startLive(candidate, generation: current)
            startOnlineCheck(candidate, generation: current)
            startEnergyRefresh(generation: current)
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
        pushed[id] = nil
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
            // With a live connection the unit's own report usually arrives first; check for it before polling.
            var waited = 0.0
            while liveConnected, waited < delay {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 0.2
                guard current == generation, commandSerial[id] == serial else { return }
                if let live = pushed[id], live.confirms(command) {
                    replace(live)
                    lastReported[id] = live
                    lastUpdated = Date()
                    finishPending(id)
                    return
                }
            }
            if !liveConnected { try? await Task.sleep(for: .seconds(delay)) }
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
        lastPolled = Date()
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

    // MARK: Live updates (MQTT)

    private func startLive(_ client: CloudClient, generation current: Int) {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            for await event in await client.liveUpdates() {
                guard let self, current == self.generation else { return }
                switch event {
                case .connected:
                    self.liveConnected = true
                    // Catch up on anything that changed while disconnected (skipped right after sign-in's own fetch).
                    if let last = self.lastPolled, Date().timeIntervalSince(last) > 30 { await self.refresh() }
                case .disconnected: self.liveConnected = false
                case .update(let device): self.applyLive(device)
                }
            }
            if let self, current == self.generation { self.liveConnected = false }
        }
    }

    /// A pushed report replaces the unit's state, unless a command is still in flight (the prediction stays until it confirms).
    private func applyLive(_ device: AirConditioner) {
        guard let known = devices.first(where: { $0.id == device.id }), known.isOnline else { return }
        pushed[device.id] = device
        lastReported[device.id] = device
        guard !pendingDevices.contains(device.id) else { return }
        replace(device)
        unconfirmedDevices.remove(device.id)
        lastUpdated = Date()
    }

    // MARK: Online check

    /// How often TCL's online flag is checked. MQTT doesn't report units dropping off (they connect through
    /// TCL's own broker, so AWS presence events never fire); this is one light request for all units.
    static let onlineCheckInterval: Duration = .seconds(60)

    private func startOnlineCheck(_ client: CloudClient, generation current: Int) {
        onlineCheck?.cancel()
        onlineCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.onlineCheckInterval)
                guard !Task.isCancelled, let self, current == self.generation, self.connected else { return }
                // A full fetch in the last minute already carried the flag.
                if let last = self.lastPolled, Date().timeIntervalSince(last) < 60 { continue }
                guard let status = try? await client.onlineStatus(), current == self.generation else { continue }
                self.applyOnline(status)
            }
        }
    }

    private func applyOnline(_ status: [String: Bool]) {
        var cameBack = false
        for unit in devices {
            guard let online = status[unit.id], online != unit.isOnline else { continue }
            if online { cameBack = true } else { markOffline(unit) }
        }
        // A unit back online may have changed while away: fetch its full state.
        if cameBack { Task { await refresh() } }
    }

    private func markOffline(_ unit: AirConditioner) {
        if UserDefaults.standard.bool(forKey: Self.offlineAlertsKey), lastReported[unit.id]?.isOnline == true {
            postOfflineAlert(unit.name)
        }
        let offline = unit.with(online: false)
        lastReported[unit.id] = offline
        replace(offline)
        lastUpdated = Date()
    }

    // MARK: Background refresh

    /// How often units refresh while MQTT is down, so the menu bar reading and offline alerts stay current.
    static let backgroundRefreshInterval: Duration = .seconds(120)
    /// Safety poll while MQTT looks connected: catches a silently dead connection.
    static let liveSafetyInterval: TimeInterval = 10 * 60

    private func startBackgroundRefresh() {
        backgroundRefresh?.cancel()
        let current = generation
        backgroundRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundRefreshInterval)
                guard !Task.isCancelled, let self, current == self.generation, self.connected else { return }
                // Skip when something else (the open panel, a command, a reconnect) fetched recently.
                let quiet = self.liveConnected ? Self.liveSafetyInterval : 60
                if let last = self.lastPolled, Date().timeIntervalSince(last) < quiet { continue }
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

    // MARK: Electricity

    /// TCL updates daily kWh slowly, so a quarter-hour keeps the panel's figures current without extra load.
    static let energyRefreshInterval: Duration = .seconds(15 * 60)

    /// Loads every unit's electricity figures at sign-in, then refreshes them on an interval.
    private func startEnergyRefresh(generation current: Int) {
        energyRefresh?.cancel()
        energyRefresh = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, current == self.generation, self.connected else { return }
                for device in self.devices where device.isOnline && device.isSupported {
                    await self.loadEnergy(for: device)
                }
                try? await Task.sleep(for: Self.energyRefreshInterval)
            }
        }
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
        liveTask?.cancel()
        liveTask = nil
        liveConnected = false
        onlineCheck?.cancel()
        onlineCheck = nil
        energyRefresh?.cancel()
        energyRefresh = nil
        pushed = [:]
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
