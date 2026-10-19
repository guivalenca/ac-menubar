import Foundation
import Network

/// A V3 Midea air conditioner on the local network. Commands are serialized; the TCP connection and
/// session key are reused and re-established transparently (ported from msmart-ng's lan.py).
public actor MideaDevice {
    /// Timeouts and retry counts. Internal so tests can shorten them; production always uses the defaults.
    struct Timing: Sendable {
        var readTimeout: TimeInterval = 2   // per packet read
        var attempts = 3                    // writes of the same packet before giving up on a timeout
        var settle: TimeInterval = 1        // pause after authenticating, before the first request
        var connectTimeout = 5              // TCP connection establishment, in seconds
    }

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Bytes, Error>
        let timeout: Task<Void, Never>
    }

    public let deviceID: UInt64
    public private(set) var host: String
    public let port: UInt16
    private let token: Bytes
    private let key: Bytes
    private let timing: Timing

    private var connection: NWConnection?
    private var generation = 0
    private var clientDisconnects = 0
    private var localKey: Bytes?
    private var authExpiry: Date?
    private var packetID: UInt16 = 0
    private var messageID: UInt8 = 0
    private var buffer: Bytes = []
    private var queued: [Bytes] = []
    private var waiter: Waiter?
    private var waiterSeq = 0

    // Serializes public operations; actor reentrancy would otherwise interleave request/response pairs.
    private var busy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    public init(host: String, port: UInt16 = 6444, deviceID: UInt64, token: Bytes, key: Bytes) {
        self.init(host: host, port: port, deviceID: deviceID, token: token, key: key, timing: Timing())
    }

    init(host: String, port: UInt16, deviceID: UInt64, token: Bytes, key: Bytes, timing: Timing) {
        self.host = host
        self.port = port
        self.deviceID = deviceID
        self.token = token
        self.key = key
        self.timing = timing
    }

    deinit { connection?.cancel() }

    // MARK: - Public API

    /// Throws `CancellationError` without sending anything if the caller is cancelled before its turn.
    public func refresh() async throws -> ACState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let frames = try await sendRetrying { ACFrame.getState(messageID: self.nextMessageID()) }
        guard let state = Self.lastState(in: frames) else { throw MideaError.noStateResponse }
        return state
    }

    /// Sends the full desired state. Returns the state the device reports back, if it sent one.
    /// Throws `CancellationError` without sending anything if the caller is cancelled before its turn,
    /// so a superseded state is never sent.
    @discardableResult
    public func apply(_ state: ACState, beep: Bool) async throws -> ACState? {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let frames = try await sendRetrying { ACFrame.setState(state, beep: beep, messageID: self.nextMessageID()) }
        return Self.lastState(in: frames)
    }

    /// Points the device at a new address. A request in flight is retried there.
    public func setHost(_ newHost: String) {
        guard newHost != host else { return }
        host = newHost
        reset(.connectionClosed)
    }

    /// Closes the connection. A request in flight fails with `.closedByClient` rather than reconnecting;
    /// the next request reconnects.
    public func disconnect() {
        clientDisconnects += 1
        reset(.closedByClient)
    }

    // MARK: - Request/response

    private static func lastState(in frames: [Bytes]) -> ACState? {
        frames.compactMap { try? ACFrame.parseState(frame: $0) }.last
    }

    private var hasSession: Bool {
        guard connection != nil, localKey != nil, let authExpiry else { return false }
        return authExpiry > Date()
    }

    /// One transparent reconnect when the connection breaks under a session that was already up (the
    /// device drops idle connections and session keys expire) or `setHost` moved the device mid-request.
    /// Nothing else is retried: `send` has already resent on timeouts, and bad replies, authentication
    /// errors, or a connection that was just opened won't get better by reconnecting.
    private func sendRetrying(_ makeFrame: () -> Bytes) async throws -> [Bytes] {
        let disconnects = clientDisconnects
        var mayRetry = true
        while true {
            let reused = hasSession
            let startHost = host
            do {
                return try await send(makeFrame())
            } catch let error as MideaError where error.isTransportFailure {
                guard clientDisconnects == disconnects else { throw MideaError.closedByClient }
                guard mayRetry, reused || host != startHost else { throw error }
                mayRetry = false
                try Task.checkCancellation()
            }
        }
    }

    private func send(_ frame: Bytes) async throws -> [Bytes] {
        try await ensureAuthenticated()
        try Task.checkCancellation()   // a fresh session stays up for the next caller
        guard let localKey else { throw MideaError.notConnected }

        let packet = try MideaPacket.encode(deviceID: deviceID, frame: frame)
        var packets = queued   // anything that arrived unsolicited
        queued.removeAll()

        let responseIndex = packets.count
        var attempt = 1
        do {
            while true {
                try await write(MideaV3.encodeEncrypted(packetID: nextPacketID(), data: packet, localKey: localKey))
                do {
                    packets.append(try await readPacket(timeout: timing.readTimeout))
                    break
                } catch MideaError.timeout where attempt < timing.attempts {
                    attempt += 1
                }
            }
        } catch {
            reset()
            throw error
        }
        packets += queued
        queued.removeAll()

        var frames: [Bytes] = []
        for (index, packet) in packets.enumerated() {
            do {
                guard case .payload(let v2) = try MideaV3.process(packet: packet, localKey: localKey) else { continue }
                frames.append(try MideaPacket.decode(v2))
            } catch where index != responseIndex {
                continue   // ignore malformed extras, but not the response we waited for
            } catch {
                reset()
                throw error
            }
        }
        return frames
    }

    private func ensureAuthenticated() async throws {
        if hasSession { return }

        try await connect()
        let gen = generation
        var attempt = 1
        while true {
            do {
                try await write(MideaV3.encodeHandshake(packetID: nextPacketID(), token: token))
                let packet = try await readPacket(timeout: timing.readTimeout)
                guard case .handshake(let payload) = try MideaV3.process(packet: packet, localKey: nil) else {
                    throw MideaError.authenticationFailed("resposta inesperada")
                }
                localKey = try MideaV3.localKey(cloudKey: key, handshakePayload: payload)
                break
            } catch MideaError.timeout where attempt < timing.attempts {
                attempt += 1
            } catch {
                reset()
                if case MideaError.protocolError = error { throw MideaError.authenticationFailed("o ar recusou o token") }
                throw error
            }
        }
        // msmart-ng waits briefly before the first request after authenticating. Cancellation doesn't cut
        // the wait short, and the session only counts as ready once it is over, so it is never skipped.
        await Self.sleepIgnoringCancellation(timing.settle)
        guard gen == generation else { throw MideaError.connectionClosed }
        authExpiry = Date().addingTimeInterval(12 * 3600)
    }

    private static func sleepIgnoringCancellation(_ seconds: TimeInterval) async {
        // A detached task doesn't inherit the caller's cancellation.
        await Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }.value
    }

    // MARK: - Connection

    private func connect() async throws {
        reset()
        let gen = generation
        packetID = 0

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw MideaError.notConnected }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = timing.connectTimeout
        // Notices a unit that dropped off the network after about 35 s of silence, so the next request
        // reconnects instead of timing out on a dead connection.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        connection = conn

        // connectionTimeout bounds the TCP handshake; this is a backstop for anything else that stalls.
        let safetyTimeout = DispatchTimeInterval.seconds(timing.connectTimeout + 2)
        let once = Once()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { [weak self, weak conn] state in
                    switch state {
                    case .ready:
                        if once.claim() { cont.resume() }
                    case .waiting(let error), .failed(let error):
                        // .waiting would wait indefinitely for the network to change: treat it as a failure.
                        if once.claim() {
                            let reason = conn?.currentPath?.unsatisfiedReason
                            cont.resume(throwing: Self.connectionError(error, unsatisfiedReason: reason))
                        }
                        Task { await self?.connectionEnded(gen: gen) }
                    case .cancelled:
                        if once.claim() { cont.resume(throwing: MideaError.connectionClosed) }
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + safetyTimeout) {
                    if once.claim() { cont.resume(throwing: MideaError.timeout) }
                }
            }
        } catch {
            if gen == generation { reset() }
            throw error
        }
        receiveLoop(conn, gen: gen)
    }

    /// A path macOS refused for lack of Local Network access becomes `.localNetworkDenied`, whatever
    /// error came with it (often EHOSTUNREACH, which a VPN can also cause).
    nonisolated static func connectionError(_ error: NWError,
                                            unsatisfiedReason: NWPath.UnsatisfiedReason? = nil) -> MideaError {
        if unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        if case .posix(let code) = error {
            return .connectionFailed(error.localizedDescription, posixCode: code.rawValue)
        }
        return .connectionFailed(error.localizedDescription, posixCode: nil)
    }

    /// Tears down the connection and session. A read in progress fails with `reason`.
    private func reset(_ reason: MideaError = .connectionClosed) {
        generation += 1
        connection?.cancel()
        connection = nil
        localKey = nil
        authExpiry = nil
        buffer.removeAll()
        queued.removeAll()
        failWaiter(reason)
    }

    private nonisolated func receiveLoop(_ conn: NWConnection, gen: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty { await self.ingest(Bytes(data), gen: gen) }
                if isComplete || error != nil {
                    await self.connectionEnded(gen: gen)
                } else {
                    self.receiveLoop(conn, gen: gen)
                }
            }
        }
    }

    private func ingest(_ bytes: Bytes, gen: Int) {
        guard gen == generation else { return }
        buffer += bytes
        for packet in MideaV3.extractPackets(from: &buffer) {
            if let w = takeWaiter() {
                w.continuation.resume(returning: packet)
            } else {
                queued.append(packet)
            }
        }
    }

    private func connectionEnded(gen: Int) {
        guard gen == generation else { return }
        reset()
    }

    private func write(_ bytes: Bytes) async throws {
        guard let conn = connection else { throw MideaError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: Self.connectionError(error)) } else { cont.resume() }
            })
        }
    }

    private func readPacket(timeout: TimeInterval) async throws -> Bytes {
        if !queued.isEmpty { return queued.removeFirst() }
        guard connection != nil else { throw MideaError.notConnected }
        waiterSeq += 1
        let id = waiterSeq
        return try await withCheckedThrowingContinuation { cont in
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.expireWaiter(id: id)
            }
            waiter = Waiter(id: id, continuation: cont, timeout: timer)
        }
    }

    /// Clears the pending read and stops its timeout.
    private func takeWaiter() -> Waiter? {
        guard let w = waiter else { return nil }
        waiter = nil
        w.timeout.cancel()
        return w
    }

    private func expireWaiter(id: Int) {
        guard waiter?.id == id else { return }
        takeWaiter()?.continuation.resume(throwing: MideaError.timeout)
    }

    private func failWaiter(_ error: Error) {
        takeWaiter()?.continuation.resume(throwing: error)
    }

    // MARK: - Counters and lock

    private func nextPacketID() -> UInt16 {
        defer { packetID = (packetID + 1) & 0xFFF }
        return packetID
    }

    private func nextMessageID() -> UInt8 {
        messageID &+= 1
        return messageID
    }

    /// Callers waiting for the lock (for tests).
    var queuedCallers: Int { lockWaiters.count }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    private func release() {
        if lockWaiters.isEmpty {
            busy = false
        } else {
            lockWaiters.removeFirst().resume()
        }
    }
}

extension MideaError {
    /// The connection broke or never came up, as opposed to the device answering badly or not at all.
    var isTransportFailure: Bool {
        switch self {
        case .connectionClosed, .connectionFailed, .notConnected: return true
        default: return false
        }
    }
}

/// Thread-safe one-shot flag for resuming a continuation exactly once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
