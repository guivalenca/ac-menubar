import Darwin
import Foundation
import MideaKit
import Network

/// Decides whether the Mac is at home, which shows the menu bar item. Sharing the air conditioner's
/// /24 isn't enough (routers of the same ISP or brand tend to ship the same default LAN): the unit
/// itself, matched by device id, must have answered on the current network, by discovery or by a
/// successful request.
///
/// - Show once the unit has answered since the last real network change: the set of IPv4 addresses on
///   the unit's /24 changed, or the path went unsatisfied and came back. Leaving Wi-Fi removes the /24
///   address and joining another network re-adds it, so another network on the same default /24 counts as a change.
///   Interfaces outside the /24 (a VPN's utun, VM bridges) don't: with NordVPN up the item stays and the
///   panel says "Sem acesso à rede local (VPN?)".
/// - Keep showing while some interface (Wi-Fi, Ethernet, any other) stays on the unit's /24, even if
///   the unit stops answering; the panel then shows it offline. Request failures never hide the item.
/// - Hide, after a 10 s grace period and a second check, when no interface is on that /24 any more, or
///   after a real network change until the unit answers on the new network.
///
/// While on the /24 but unconfirmed, the monitor probes: discovery right away and, when the unit is
/// silent, `.silent` asks the store for one TCP try. Rounds back off from 30 s to 5 min and start over
/// on a real network change. Away, nothing runs: NWPathMonitor reports network changes. At home the
/// store's poll takes over and calls `lookForDevice()` (same backoff) when the unit stops answering, in
/// case the router gave it a new address. Reading the interfaces is one getifaddrs call: no
/// subprocesses, no packets.
@MainActor
final class HomeNetworkMonitor {
    struct Device: Sendable {
        let id: UInt64
        var host: String
    }

    struct Interface: Hashable, Sendable {
        let name: String
        let ip: String
    }

    enum Finding: Equatable, Sendable {
        /// The configured unit answered discovery from `ip`.
        case device(ip: String)
        /// On the unit's /24 and unconfirmed, and the unit didn't answer discovery: worth one TCP try.
        case silent(Interface)
        /// No interface is on the unit's /24.
        case away(String)
    }

    /// Where the Mac stands; logged when it changes.
    enum Status: Equatable, CustomStringConvertible {
        case away(String)
        case unconfirmed(Interface)
        case home(Interface)

        var description: String {
            switch self {
            case .away(let detail): return "away (\(detail))"
            case .unconfirmed(let i): return "\(i.ip) on \(i.name) shares the air conditioner's subnet, waiting for it to answer"
            case .home(let i): return "home (\(i.ip) on \(i.name), the air conditioner answered on this network)"
            }
        }
    }

    static let hideDelay: Duration = .seconds(10)
    static let pathSettle: Duration = .seconds(2)
    static let discoveryTimeout: TimeInterval = 2.5
    static let firstDiscoveryBackoff: Duration = .seconds(30)
    static let maxDiscoveryBackoff: Duration = .seconds(300)

    /// Whether the menu bar item should show (the store adds its own exceptions).
    private(set) var isHome = false
    /// Bumped on every real network change. Read it when a request starts and pass it to
    /// `deviceAnswered(onNetwork:)`, so an answer that began on the previous network confirms nothing.
    private(set) var networkID = 0
    var onHomeChange: (@MainActor (Bool) -> Void)?
    /// Discovery replies, silent probes and away checks, delivered before any `onHomeChange` they cause.
    var onFinding: (@MainActor (Finding) -> Void)?

    private var device: Device?
    private let interfaces: () -> [Interface]
    private let discover: @Sendable () async -> [DiscoveredDevice]
    private let pathMonitor = NWPathMonitor()
    private var pathDebounce: Task<Void, Never>?
    private var pathWasUnsatisfied = false
    /// The interfaces on the unit's /24 at the last reading; nil until the first one.
    private var lastSubnetInterfaces: Set<Interface>?
    /// The interface on the unit's /24 at the last reading.
    private var subnetInterface: Interface?
    /// The unit answered since the last real network change.
    private var confirmed = false
    private var lastStatus: Status?
    private var hideTimer: Task<Void, Never>?
    private var discovery: Task<Void, Never>?
    private var probeTimer: Task<Void, Never>?
    private var nextDiscovery: ContinuousClock.Instant?
    private var discoveryBackoff = HomeNetworkMonitor.firstDiscoveryBackoff

    /// `interfaces` and `discover` default to the real network; harnesses pass fakes.
    init(device: Device?,
         interfaces: @escaping () -> [Interface] = { HomeNetworkMonitor.ipv4Interfaces() },
         discover: @escaping @Sendable () async -> [DiscoveredDevice] = {
             await MideaDiscovery.discover(timeout: HomeNetworkMonitor.discoveryTimeout)
         }) {
        self.device = device
        self.interfaces = interfaces
        self.discover = discover
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathUpdated(satisfied: satisfied) }
        }
        pathMonitor.start(queue: .main)
        check()
    }

    /// Reads the interfaces now. Shows the item if the unit has answered on this network; otherwise
    /// starts the grace period (when shown) and probes (when on the unit's /24).
    func check() {
        evaluate(final: false)
    }

    /// The unit stopped answering at home: discovery, in case it has a new address. Rate-limited by
    /// the backoff, and it never hides the item, whatever it finds.
    func lookForDevice() {
        guard isHome, discoveryDue else { return }
        startDiscovery()
    }

    /// A request that started on network `id` succeeded: the unit answered.
    func deviceAnswered(onNetwork id: Int) {
        if id == networkID { resetDiscoveryBackoff() }   // when the unit goes silent later, look right away
        confirm(onNetwork: id, by: "a request")
    }

    func setDeviceHost(_ host: String) {
        // On a new /24, the next reading is the new baseline rather than a network change.
        if let old = device?.host, Self.subnet24(old) != Self.subnet24(host) { lastSubnetInterfaces = nil }
        device?.host = host
    }

    // MARK: - State

    /// Path updates arrive in bursts (waking, roaming, VPNs). Each one is checked for a real network
    /// change at once, so a brief gap isn't missed; the rest waits for the burst to settle.
    private func pathUpdated(satisfied: Bool) {
        if !satisfied {
            pathWasUnsatisfied = true
        } else if pathWasUnsatisfied {
            pathWasUnsatisfied = false
            networkChanged("the network dropped and came back")
        }
        readInterfaces()
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.pathSettle, tolerance: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.check()
        }
    }

    /// `final` is the check at the end of the grace period: anything but home there hides the item.
    private func evaluate(final: Bool) {
        let list = readInterfaces()
        let status: Status
        if let match = subnetInterface {
            status = confirmed ? .home(match) : .unconfirmed(match)
        } else {
            status = .away(Self.describe(list))
        }
        log(status)
        if case .away(let detail) = status { onFinding?(.away(detail)) }

        if case .home = status {
            cancelHide()
            setHome(true)
        } else if final {
            setHome(false)
        } else if isHome, hideTimer == nil {
            // Ride out short blips (roaming, waking from sleep) and give the unit time to answer.
            hideTimer = Task { [weak self] in
                try? await Task.sleep(for: Self.hideDelay, tolerance: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.hideTimer = nil
                self.evaluate(final: true)
            }
        }
        probeIfUnconfirmed()
    }

    /// Reads the interfaces. A different set of addresses on the unit's /24 is a real network change;
    /// interfaces anywhere else are ignored.
    @discardableResult
    private func readInterfaces() -> [Interface] {
        let list = interfaces()
        let onSubnet = Self.subnetInterfaces(for: device, in: list)
        let current = Set(onSubnet)
        if let last = lastSubnetInterfaces, last != current {
            networkChanged("on the air conditioner's subnet: \(Self.describe(Array(last))) -> \(Self.describe(onSubnet))")
        }
        lastSubnetInterfaces = current
        subnetInterface = onSubnet.first
        return list
    }

    /// The unit must answer again before the item shows (or stays shown past the grace period).
    private func networkChanged(_ reason: String) {
        networkID += 1
        Log.write("network changed: \(reason)")
        confirmed = false
        resetDiscoveryBackoff()
        cancelHide()   // the next check starts a fresh grace period
        probeTimer?.cancel()   // and probes the new network once it has settled
        probeTimer = nil
    }

    private func confirm(onNetwork id: Int, by source: String) {
        guard id == networkID else { return }
        // A discovery reply while already confirmed keeps the backoff: a unit that answers discovery
        // but not requests would otherwise get a discovery on every failed poll.
        if !confirmed {
            confirmed = true
            resetDiscoveryBackoff()
            Log.write("network: the air conditioner answered \(source)")
        }
        probeIfUnconfirmed()   // stops probing
        guard let match = subnetInterface else { return }
        log(.home(match))
        cancelHide()
        setHome(true)
    }

    private func log(_ status: Status) {
        guard status != lastStatus else { return }
        lastStatus = status
        Log.write("network: \(status)")
    }

    private func cancelHide() {
        hideTimer?.cancel()
        hideTimer = nil
    }

    private func setHome(_ home: Bool) {
        guard home != isHome else { return }
        isHome = home
        Log.write("home: \(home ? "yes" : "no")")
        onHomeChange?(home)
    }

    // MARK: - Discovery

    private var discoveryDue: Bool {
        guard discovery == nil else { return false }
        guard let nextDiscovery else { return true }
        return ContinuousClock.now >= nextDiscovery
    }

    /// While on the unit's /24 and unconfirmed: a discovery round if the backoff allows, otherwise a
    /// timer for the next one. Anywhere else it stops the timer.
    private func probeIfUnconfirmed() {
        probeTimer?.cancel()
        probeTimer = nil
        guard subnetInterface != nil, !confirmed, discovery == nil else { return }
        if discoveryDue {
            startDiscovery()
        } else if let next = nextDiscovery {
            probeTimer = Task { [weak self] in
                try? await Task.sleep(until: next, tolerance: .seconds(5), clock: .continuous)
                guard let self, !Task.isCancelled else { return }
                self.probeTimer = nil
                self.check()
            }
        }
    }

    private func startDiscovery() {
        guard let device, discovery == nil else { return }
        let backoff = discoveryBackoff
        nextDiscovery = .now + backoff
        discoveryBackoff = min(backoff * 2, Self.maxDiscoveryBackoff)
        let id = networkID
        discovery = Task { [weak self, discover] in
            let found = await discover()
            guard let self else { return }
            self.discovery = nil
            if let match = found.first(where: { $0.id == device.id }) {
                self.onFinding?(.device(ip: match.ip))
                self.confirm(onNetwork: id, by: "discovery from \(match.ip)")
            } else {
                if backoff < Self.maxDiscoveryBackoff {
                    Log.write("network: air conditioner silent on discovery, next try in \(backoff.components.seconds) s or more")
                }
                if id == self.networkID, !self.confirmed, let match = self.subnetInterface {
                    self.onFinding?(.silent(match))
                }
            }
            self.probeIfUnconfirmed()
        }
    }

    private func resetDiscoveryBackoff() {
        nextDiscovery = nil
        discoveryBackoff = Self.firstDiscoveryBackoff
    }

    // MARK: - Evidence

    /// The interfaces on `device`'s /24.
    nonisolated static func subnetInterfaces(for device: Device?, in interfaces: [Interface]) -> [Interface] {
        guard let device, let home = subnet24(device.host) else { return [] }
        return interfaces.filter { subnet24($0.ip) == home }
    }

    /// The first interface on `device`'s /24, if any.
    nonisolated static func subnetInterface(for device: Device?, in interfaces: [Interface]) -> Interface? {
        subnetInterfaces(for: device, in: interfaces).first
    }

    nonisolated static func describe(_ interfaces: [Interface]) -> String {
        if interfaces.isEmpty { return "no IPv4 address" }
        return interfaces.sorted { $0.name < $1.name }.map { "\($0.ip) on \($0.name)" }.joined(separator: ", ")
    }

    /// IPv4 addresses of the interfaces that are up, except loopback and link-local (169.254.x.x).
    nonisolated static func ipv4Interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }).map(\.pointee) {
            let flags = entry.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var address = sin.pointee.sin_addr
                _ = inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: buffer)
            if !ip.isEmpty, !ip.hasPrefix("169.254.") {
                found.append(Interface(name: String(cString: entry.ifa_name), ip: ip))
            }
        }
        return found
    }

    /// "192.168.0" for "192.168.0.7"; nil for anything that isn't a dotted IPv4 address.
    nonisolated static func subnet24(_ ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }
}
