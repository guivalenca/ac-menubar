import AppKit
import Combine
import Foundation
import MideaKit

/// App state for one air conditioner: polling, optimistic edits and recovery.
///
/// Views observe this object, so every @Published write re-renders them. Writes are skipped when the
/// value didn't change, and background polls touch nothing unless the unit reported something new.
@MainActor
final class ACStore: ObservableObject {
    enum Sync: Equatable {
        case idle
        case syncing
        case offline(String)
        /// macOS refused the connection because the app lacks Local Network access
        /// (`MideaError.localNetworkDenied`).
        case blocked
    }

    /// The app's only store, created on first use (after App.init's snapshot check).
    static let shared = ACStore()

    /// Drives MenuBarExtra(isInserted:): shown at home, or anywhere while something needs the user.
    let visibility = MenuBarVisibility()
    @Published private(set) var state: ACState?
    @Published private(set) var sync: Sync = .idle
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var setupError: String?
    @Published var beepEnabled: Bool {
        didSet { UserDefaults.standard.set(beepEnabled, forKey: "beep") }
    }

    let deviceName: String
    private var config: ACAppConfig
    private var device: MideaDevice?
    private let network: HomeNetworkMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var pollTask: Task<Void, Never>?
    /// Waits out an edit's debounce. A newer edit cancels it: the only cancellation in the store.
    private var debounceTask: Task<Void, Never>?
    /// Sends the newest state, and again if edits arrived meanwhile. Never cancelled, so a write that
    /// has started always finishes.
    private var applyTask: Task<Void, Never>?
    private var applyAgain = false
    private var refreshing = false
    /// Bumped on every local edit so that device reports for older states don't overwrite newer edits.
    private var revision = 0
    private var home = false
    private var failures = 0
    private var lastLoggedError: String?

    private convenience init() {
        var loaded = ACAppConfig()
        var problem: String?
        var made: MideaDevice?
        do {
            loaded = try ACConfigStore.load()
            if let first = loaded.devices.first {
                made = try first.makeDevice()
            } else {
                problem = "Nenhum ar-condicionado configurado."
            }
        } catch let error as MideaError {
            problem = error.localizedDescription
        } catch {
            problem = "Não encontrei a configuração em ~/.config/ac-menubar/config.json."
        }
        let target = loaded.devices.first.map { HomeNetworkMonitor.Device(id: $0.id, host: $0.host) }
        self.init(config: loaded, device: made, setupError: problem, network: HomeNetworkMonitor(device: target))
    }

    /// The live store. `shared` loads its pieces from the configuration file; harnesses pass their own.
    init(config: ACAppConfig, device: MideaDevice?, setupError: String?, network: HomeNetworkMonitor) {
        beepEnabled = UserDefaults.standard.object(forKey: "beep") as? Bool ?? true
        self.config = config
        self.device = device
        self.setupError = setupError
        deviceName = config.devices.first?.name ?? "Ar"
        self.network = network
        if let setupError { Log.write("setup error: \(setupError)") }

        network.onFinding = { [weak self] finding in self?.networkFound(finding) }
        network.onHomeChange = { [weak self] home in self?.homeChanged(home) }

        // The panel is the app's only window: refresh whenever it opens.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshNow() } }
            .store(in: &cancellables)

        updateVisibility()
        network.start()
    }

    /// Static instance for snapshots; never touches the network.
    init(preview state: ACState?, sync: Sync = .idle, lastUpdate: Date? = Date(), name: String = "Sala") {
        beepEnabled = true
        config = ACAppConfig()
        deviceName = name
        network = nil
        self.state = state
        self.sync = sync
        self.lastUpdate = lastUpdate
        visibility.isVisible = true
    }

    // MARK: - Derived

    var isOn: Bool { state?.power ?? false }

    /// Menu bar text: the setpoint while running, the room temperature otherwise.
    var menuBarText: String? {
        guard let state else { return nil }
        if state.power { return Format.degrees(state.targetTemperature) }
        return state.indoorTemperature.map(Format.degrees)
    }

    private var deviceHost: String? { config.devices.first?.host }

    /// An edit is waiting out its debounce or being sent.
    private var editPending: Bool { debounceTask != nil || applyTask != nil }

    // MARK: - Network

    private func updateVisibility() {
        visibility.isVisible = home || setupError != nil || sync == .blocked
    }

    private func homeChanged(_ home: Bool) {
        self.home = home
        failures = 0
        if !home, case .offline = sync { setSync(.idle) }
        updateVisibility()
        pollTask?.cancel()
        pollTask = nil
        guard home, device != nil else {
            if let device { Task { await device.disconnect() } }
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Skip the first poll when a refresh just happened.
                if self.lastUpdate.map({ Date().timeIntervalSince($0) > 10 }) ?? true { await self.refresh() }
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))
            }
        }
    }

    private func networkFound(_ finding: HomeNetworkMonitor.Finding) {
        switch finding {
        case .device(let ip):
            adoptHost(ip)
        case .silent:
            // On the unit's subnet, not confirmed yet, and discovery got no reply: try TCP once. Success
            // confirms home; a Local Network denial shows the item so the panel can explain it.
            Task { await refresh() }
        case .away:
            if sync == .blocked { setSync(.idle) }
            updateVisibility()
        }
    }

    /// The unit answered discovery from a new address: use it from now on, and save it.
    private func adoptHost(_ ip: String) {
        guard let entry = config.devices.first, entry.host != ip else { return }
        Log.write("air conditioner moved from \(entry.host) to \(ip)")
        config.devices[0].host = ip
        saveHost(ip, forDevice: entry.id)
        network?.setDeviceHost(ip)
        failures = 0
        if home { Task { await refresh() } }
    }

    /// Patches this unit's address into the file as it is now, so edits made by hand since launch
    /// survive. A file that exists but doesn't load (say, half edited) is never overwritten: the app
    /// keeps the new address in memory only. A missing file gets the copy loaded at launch.
    private func saveHost(_ ip: String, forDevice id: UInt64) {
        var file: ACAppConfig
        do {
            file = try ACConfigStore.load()
        } catch {
            guard !FileManager.default.fileExists(atPath: ACConfigStore.url.path) else {
                Log.write("not saving the new address: the configuration file exists but doesn't load: \(error)")
                return
            }
            Log.write("the configuration file is missing; saving the copy loaded at launch")
            file = config
        }
        guard let index = file.devices.firstIndex(where: { $0.id == id }) else {
            Log.write("the configuration no longer lists air conditioner \(id); not saving its address")
            return
        }
        file.devices[index].host = ip
        do {
            try ACConfigStore.save(file)
        } catch {
            Log.write("saving the new address failed: \(error)")
        }
    }

    // MARK: - Refresh

    /// For user actions: opening the panel, "Atualizar agora", "Tentar de novo".
    func refreshNow() {
        if home {
            Task { await refresh(showProgress: sync != .blocked) }
        } else {
            // The panel is open away from home only to explain a block or a setup error: re-read the
            // network and try the unit, which also tells whether Local Network access was granted.
            network?.check()
            Task { await refresh() }
        }
    }

    /// Fetches the unit's state. `sync` only changes when the outcome differs, so a background poll
    /// that finds nothing new costs a single `lastUpdate` write.
    private func refresh(showProgress: Bool = false) async {
        guard let device, let host = deviceHost, !editPending, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let rev = revision
        let networkID = network?.networkID ?? 0
        if showProgress { setSync(.syncing) }
        do {
            await device.setHost(host)
            let reported = try await device.refresh()
            succeeded(reported: rev == revision && !editPending ? reported : nil, networkID: networkID)
        } catch {
            failed(error)
        }
    }

    /// `networkID` is the monitor's network when the request started.
    private func succeeded(reported: ACState?, networkID: Int) {
        if let reported, reported != state { state = reported }
        if lastUpdate == nil {
            Log.write("first refresh ok")
        } else if lastLoggedError != nil {
            Log.write("refresh ok again after \(failures) failure\(failures == 1 ? "" : "s")")
        }
        lastLoggedError = nil
        failures = 0
        lastUpdate = Date()
        setSync(.idle)
        network?.deviceAnswered(onNetwork: networkID)
        updateVisibility()
    }

    private func failed(_ error: Error) {
        // Cancellation and disconnect() are the app's own doing (leaving home), not the unit failing:
        // no log, no count, no offline status.
        if Task.isCancelled || Self.isIgnorable(error) {
            if sync == .syncing { setSync(.idle) }
            return
        }

        let description = String(describing: error)
        if description != lastLoggedError {
            Log.write("error: \(description)")
            lastLoggedError = description
        }

        let blocked = Self.isBlocked(error)
        if blocked {
            setSync(.blocked)
        } else if home {
            setSync(.offline(Self.message(for: error)))
        } else if sync == .blocked {
            setSync(.idle)   // packets got out, so the block is gone; we're just not home
        }
        updateVisibility()

        // Maybe the router gave the unit a new address. The monitor rate-limits discovery, and nothing
        // here hides the menu bar item: only leaving the unit's subnet, or changing networks, does.
        guard home, !blocked else { return }
        failures += 1
        network?.lookForDevice()
    }

    private func setSync(_ new: Sync) {
        if sync != new { sync = new }
    }

    // MARK: - Edits

    func togglePower() { edit { $0.power.toggle() } }

    func setTarget(_ value: Double) {
        let clamped = min(max(value.rounded(), 16), 30)
        edit(debounce: .milliseconds(600)) { $0.targetTemperature = clamped }
    }

    /// From a half-degree setpoint, both directions move half a degree: 20.5 goes to 21 or 20.
    func stepTarget(_ delta: Double) {
        guard let state else { return }
        setTarget((state.targetTemperature + delta).rounded(delta > 0 ? .down : .up))
    }

    func setMode(_ mode: ACMode) { edit { $0.mode = mode } }
    func setFan(_ fan: ACFanSpeed) { edit { $0.fanSpeed = fan } }
    func setSwing(_ swing: ACSwing) { edit { $0.swing = swing } }
    func toggleSleep() { edit { $0.sleep.toggle() } }

    // Eco and turbo are mutually exclusive on Midea units.
    func toggleEco() {
        edit {
            $0.eco.toggle()
            if $0.eco { $0.turbo = false }
        }
    }

    func toggleTurbo() {
        edit {
            $0.turbo.toggle()
            if $0.turbo { $0.eco = false }
        }
    }

    /// Applies a change locally right away, then sends the full state after a short debounce. A newer
    /// edit restarts the debounce but never cancels a write already on its way; the newest state
    /// follows that write.
    private func edit(debounce: Duration = .milliseconds(150), _ change: (inout ACState) -> Void) {
        guard var next = state else { return }
        change(&next)
        guard next != state else { return }
        state = next
        revision += 1
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.debounceTask = nil
            self.sendLatest()
        }
    }

    private func sendLatest() {
        guard applyTask == nil else {
            applyAgain = true
            return
        }
        applyTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.applyAgain = false
                await self.apply()
            } while self.applyAgain
            self.applyTask = nil
        }
    }

    private func apply() async {
        guard let device, let host = deviceHost, let desired = state else { return }
        let rev = revision
        let networkID = network?.networkID ?? 0
        setSync(.syncing)
        do {
            await device.setHost(host)
            let reported = try await device.apply(desired, beep: beepEnabled)
            // After a newer edit, keep showing it rather than the state this write produced.
            succeeded(reported: rev == revision ? reported : nil, networkID: networkID)
        } catch {
            failed(error)
        }
    }

    // MARK: - Errors

    /// Only a Local Network denial: EHOSTUNREACH alone can also be a VPN, and stays an offline error.
    static func isBlocked(_ error: Error) -> Bool {
        (error as? MideaError) == .localNetworkDenied
    }

    /// Errors the app causes itself: a cancelled task, or `disconnect()` cutting a request short.
    static func isIgnorable(_ error: Error) -> Bool {
        error is CancellationError || (error as? MideaError) == .closedByClient
    }

    static func message(for error: Error) -> String {
        switch error as? MideaError {
        case .connectionFailed(_, posixCode: let code?) where code == EHOSTUNREACH:
            // No route to an address on our own subnet: usually a VPN that takes all traffic.
            return "Sem acesso à rede local (VPN?)"
        case .connectionFailed, .connectionClosed, .notConnected, .timeout:
            return "O ar não respondeu."
        case .authenticationFailed:
            return "O ar recusou a chave salva."
        default:
            return error.localizedDescription
        }
    }
}
