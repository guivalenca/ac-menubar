import Foundation
import Network
import XCTest
@testable import MideaKit

/// Minimal V3 device on 127.0.0.1 for exercising MideaDevice's connection lifecycle. It accepts any
/// token, answers every request with the captured state frame, and records what it receives.
final class FakeDevice: @unchecked Sendable {
    enum Behavior: Equatable {
        case normal
        case trailingErrorPacket   // the state response plus an error packet in the same TCP chunk
        case silent                // authenticates but never answers requests
        case hold                  // keeps responses back until release()
        case dropNextRequest       // closes the connection on the next request, then behaves normally
        case dropRequests          // closes the connection on every request
    }

    let cloudKey = MideaV3.randomBytes(16)
    let stateFrame: Bytes
    private(set) var port: UInt16 = 0

    private let lock = NSLock()
    private var _behavior: Behavior
    private var _connections = 0
    private var _handshakeTimes: [Date] = []
    private var _requests: [(time: Date, isSetState: Bool)] = []
    private var held: [(NWConnection, Data)] = []
    private var conns: [NWConnection] = []
    private let listener: NWListener

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }
    var connections: Int { lock.withLock { _connections } }
    var handshakes: Int { lock.withLock { _handshakeTimes.count } }
    var handshakeTimes: [Date] { lock.withLock { _handshakeTimes } }
    var requestTimes: [Date] { lock.withLock { _requests.map(\.time) } }
    var setStates: Int { lock.withLock { _requests.filter(\.isSetState).count } }
    var getStates: Int { lock.withLock { _requests.filter { !$0.isSetState }.count } }

    init(stateFrame: Bytes, behavior: Behavior = .normal) throws {
        self.stateFrame = stateFrame
        _behavior = behavior
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = try XCTUnwrap(listener.port?.rawValue)
    }

    func stop() {
        listener.cancel()
        lock.withLock { conns.forEach { $0.cancel() } }
    }

    /// Sends the held responses and goes back to answering normally.
    func release() {
        let pending = lock.withLock { () -> [(NWConnection, Data)] in
            _behavior = .normal
            defer { held.removeAll() }
            return held
        }
        for (c, data) in pending { c.send(content: data, completion: .idempotent) }
    }

    private final class Session: @unchecked Sendable {
        var buffer: Bytes = []
        var localKey: Bytes?
    }

    private func accept(_ c: NWConnection) {
        lock.withLock {
            _connections += 1
            conns.append(c)
        }
        c.start(queue: .global())
        receive(c, Session())
    }

    private func receive(_ c: NWConnection, _ s: Session) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { s.buffer += Bytes(data) }
            for packet in MideaV3.extractPackets(from: &s.buffer) { self.handle(packet, c, s) }
            if !done && error == nil { self.receive(c, s) }
        }
    }

    private func handle(_ p: Bytes, _ c: NWConnection, _ s: Session) {
        switch p[5] & 0xF {
        case 0x0:   // handshake request
            let x = MideaV3.randomBytes(32)
            s.localKey = zip(x, cloudKey).map { $0 ^ $1 }
            let payload = try! MideaCrypto.encryptCBC(key: cloudKey, x) + MideaCrypto.sha256(x)
            lock.withLock { _handshakeTimes.append(Date()) }
            c.send(content: Data(MideaV3.header(length: 64, typeByte: 0x1) + [0, 0] + payload), completion: .idempotent)

        case 0x6:   // encrypted request
            guard let key = s.localKey else { return }
            let pad = Int(p[5] >> 4)
            let decrypted = try! MideaCrypto.decryptCBC(key: key, Bytes(p[6..<(p.count - 32)]))
            let frame = try! MideaPacket.decode(Bytes(decrypted[2..<(decrypted.count - pad)]))

            let v2 = try! MideaPacket.encode(deviceID: 1, frame: stateFrame)
            let remainder = (v2.count + 2) % 16
            let rpad = remainder == 0 ? 0 : 16 - remainder
            let hdr = MideaV3.header(length: v2.count + rpad + 32, typeByte: UInt8(rpad << 4) | 0x3)
            let plain = Bytes(decrypted[0..<2]) + v2 + Bytes(repeating: 0, count: rpad)
            var response = hdr + (try! MideaCrypto.encryptCBC(key: key, plain)) + MideaCrypto.sha256(hdr + plain)

            let behavior = lock.withLock { () -> Behavior in
                _requests.append((Date(), frame[10] == 0x40))
                let b = _behavior
                if b == .dropNextRequest { _behavior = .normal }
                if b == .hold { held.append((c, Data(response))) }
                return b
            }
            switch behavior {
            case .silent, .hold:
                return
            case .dropNextRequest, .dropRequests:
                c.cancel()
                return
            case .trailingErrorPacket:
                response += MideaV3.header(length: 0, typeByte: 0x0F) + [0, 0]
            case .normal:
                break
            }
            c.send(content: Data(response), completion: .idempotent)

        default:
            break
        }
    }
}

final class FakeDeviceTests: XCTestCase {
    private struct WaitTimedOut: Error {}

    private var stateFrame: Bytes = []
    private var reportedState = ACState()
    private let token = Bytes(repeating: 7, count: 64)

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Vectors", withExtension: "json"))
        let v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let response = try XCTUnwrap(v["state_response"] as? [String: Any])
        stateFrame = try XCTUnwrap(Bytes(hex: try XCTUnwrap(response["frame"] as? String)))
        reportedState = try XCTUnwrap(ACFrame.parseState(frame: stateFrame))
    }

    /// Short timeouts keep the suite fast; testProductionTiming pins the real defaults.
    private func makeDevice(_ fake: FakeDevice, readTimeout: TimeInterval = 0.3,
                            settle: TimeInterval = 0.2) -> MideaDevice {
        MideaDevice(host: "127.0.0.1", port: fake.port, deviceID: 1, token: token, key: fake.cloudKey,
                    timing: .init(readTimeout: readTimeout, attempts: 3, settle: settle))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)")
                throw WaitTimedOut()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func outcome<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Runs `body` in a task that is already cancelled when it starts.
    private func cancelledCall<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await body()
        }.result
    }

    private func mideaError<T>(_ result: Result<T, Error>) -> MideaError? {
        if case .failure(let error) = result { return error as? MideaError }
        return nil
    }

    private func assertCancelled<T>(_ result: Result<T, Error>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result, error is CancellationError else {
            return XCTFail("expected CancellationError, got \(result)", file: file, line: line)
        }
    }

    // MARK: - Session reuse

    func testProductionTiming() {
        let timing = MideaDevice.Timing()
        XCTAssertEqual(timing.readTimeout, 2)
        XCTAssertEqual(timing.attempts, 3)
        XCTAssertEqual(timing.settle, 1)
        XCTAssertEqual(timing.connectTimeout, 5)
    }

    func testSessionIsReusedAndFirstRequestWaitsForSettle() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame); defer { fake.stop() }
        let device = makeDevice(fake)
        let first = try await device.refresh()
        let second = try await device.refresh()
        XCTAssertEqual(first, reportedState)
        XCTAssertEqual(second, reportedState)
        XCTAssertEqual(fake.connections, 1)
        XCTAssertEqual(fake.handshakes, 1)
        let gap = try XCTUnwrap(fake.requestTimes.first).timeIntervalSince(try XCTUnwrap(fake.handshakeTimes.first))
        XCTAssertGreaterThanOrEqual(gap, 0.2)
    }

    // MARK: - Retries (finding 1)

    /// A unit that authenticates but never answers gets SetState `attempts` times, 2 s apart, and the
    /// call fails with .timeout after about 6 s. It used to go out 6 times with the lock held for 14 s.
    func testSilentDeviceGetsThreeSendsAndFailsInAboutSixSeconds() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame); defer { fake.stop() }
        let device = MideaDevice(host: "127.0.0.1", port: fake.port, deviceID: 1, token: token, key: fake.cloudKey)
        _ = try await device.refresh()
        fake.behavior = .silent

        let start = Date()
        let result = await outcome { try await device.apply(ACState(), beep: true) }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(mideaError(result), .timeout)
        XCTAssertEqual(fake.setStates, 3)
        XCTAssertEqual(elapsed, 6, accuracy: 0.75)
        XCTAssertEqual(fake.connections, 1)
        XCTAssertEqual(fake.handshakes, 1)
    }

    /// The device closing an established session mid-request is retried once on a new connection.
    func testDroppedSessionIsReopenedOnce() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame); defer { fake.stop() }
        let device = makeDevice(fake)
        _ = try await device.refresh()
        fake.behavior = .dropNextRequest

        let state = try await device.refresh()
        XCTAssertEqual(state, reportedState)
        XCTAssertEqual(fake.connections, 2)
        XCTAssertEqual(fake.getStates, 3)
    }

    /// A connection that was just opened and fails is not retried: reconnecting won't help.
    func testFailureOnFreshSessionIsNotRetried() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame, behavior: .dropRequests); defer { fake.stop() }
        let device = makeDevice(fake)

        let result = await outcome { try await device.apply(ACState(), beep: true) }
        let error = try XCTUnwrap(mideaError(result), "\(result)")
        XCTAssertTrue([.connectionClosed, .notConnected].contains(error) || error.isConnectionFailed, "\(error)")
        XCTAssertEqual(fake.setStates, 1)
        XCTAssertEqual(fake.connections, 1)
    }

    // MARK: - Cancellation (finding 2)

    func testCancelledCallerSendsNothingAndKeepsSession() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame); defer { fake.stop() }
        let device = makeDevice(fake)

        assertCancelled(await cancelledCall { try await device.apply(ACState(), beep: true) })
        XCTAssertEqual(fake.connections, 0, "a cancelled caller shouldn't even connect")

        _ = try await device.refresh()
        assertCancelled(await cancelledCall { try await device.apply(ACState(), beep: true) })
        _ = try await device.refresh()
        XCTAssertEqual(fake.setStates, 0)
        XCTAssertEqual(fake.connections, 1)
        XCTAssertEqual(fake.handshakes, 1)
    }

    /// A caller cancelled while waiting for the lock must not send its now stale SetState.
    func testCallerCancelledWhileQueuedSendsNothing() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame); defer { fake.stop() }
        let device = makeDevice(fake, readTimeout: 5)
        _ = try await device.refresh()
        fake.behavior = .hold

        let first = Task { try await device.apply(ACState(), beep: true) }
        try await waitUntil("the first SetState arrives") { fake.setStates == 1 }
        var stale = ACState()
        stale.targetTemperature = 29
        let queued = Task { try await device.apply(stale, beep: true) }
        try await waitUntil("the second caller is queued") { await device.queuedCallers == 1 }
        queued.cancel()
        fake.release()

        let reported = try await first.value
        XCTAssertEqual(reported, reportedState)
        assertCancelled(await queued.result)
        XCTAssertEqual(fake.setStates, 1)
        XCTAssertEqual(fake.connections, 1)
    }

    /// Cancelling during the post-auth settle neither tears the session down nor shortens the settle.
    func testCancelDuringSettleKeepsSessionAndSettle() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame); defer { fake.stop() }
        let settle = 0.5
        let device = makeDevice(fake, settle: settle)

        let task = Task { try await device.apply(ACState(), beep: true) }
        try await waitUntil("the handshake arrives") { fake.handshakes == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        assertCancelled(await task.result)
        let handshake = try XCTUnwrap(fake.handshakeTimes.last)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(handshake), settle, "the settle was cut short")
        XCTAssertEqual(fake.setStates, 0)

        let state = try await device.refresh()
        XCTAssertEqual(state, reportedState)
        XCTAssertEqual(fake.connections, 1)
        XCTAssertEqual(fake.handshakes, 1)
        let firstRequest = try XCTUnwrap(fake.requestTimes.first)
        XCTAssertGreaterThanOrEqual(firstRequest.timeIntervalSince(handshake), settle, "the settle was skipped")
    }

    // MARK: - Extra packets (finding 3)

    func testTrailingErrorPacketDoesNotDiscardState() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame, behavior: .trailingErrorPacket); defer { fake.stop() }
        let device = makeDevice(fake)

        let first = try await device.apply(ACState(), beep: true)
        let second = try await device.apply(ACState(), beep: true)
        XCTAssertEqual(first, reportedState)
        XCTAssertEqual(second, reportedState)
        XCTAssertEqual(fake.setStates, 2)
        XCTAssertEqual(fake.connections, 1)
    }

    // MARK: - disconnect() and setHost (finding 4)

    func testDisconnectDuringRequestIsNotUndone() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame); defer { fake.stop() }
        let device = makeDevice(fake, readTimeout: 5)
        _ = try await device.refresh()
        fake.behavior = .silent

        let task = Task { try await device.refresh() }
        try await waitUntil("the request arrives") { fake.getStates == 2 }
        fake.behavior = .normal
        await device.disconnect()

        let result = await task.result
        XCTAssertEqual(mideaError(result), .closedByClient)
        XCTAssertEqual(fake.connections, 1)

        // Only the request in flight is affected: the next one reconnects.
        let state = try await device.refresh()
        XCTAssertEqual(state, reportedState)
        XCTAssertEqual(fake.connections, 2)
    }

    func testSetHostDuringRequestRetriesOnNewHost() async throws {
        let fake = try FakeDevice(stateFrame: stateFrame); defer { fake.stop() }
        let device = makeDevice(fake, readTimeout: 5)
        _ = try await device.refresh()
        fake.behavior = .silent

        let task = Task { try await device.refresh() }
        try await waitUntil("the request arrives") { fake.getStates == 2 }
        fake.behavior = .normal
        await device.setHost("localhost")

        let state = try await task.value
        XCTAssertEqual(state, reportedState)
        XCTAssertEqual(fake.connections, 2)
        let host = await device.host
        XCTAssertEqual(host, "localhost")
    }

    // MARK: - Local Network privacy

    /// The path's unsatisfied reason, not the POSIX code, identifies a Local Network denial: a VPN can
    /// also produce EHOSTUNREACH.
    func testLocalNetworkDenialIsTellableFromOtherFailures() {
        let unreachable = NWError.posix(.EHOSTUNREACH)
        XCTAssertEqual(MideaDevice.connectionError(unreachable, unsatisfiedReason: .localNetworkDenied),
                       .localNetworkDenied)
        XCTAssertEqual(MideaDevice.connectionError(.posix(.ENETDOWN), unsatisfiedReason: .localNetworkDenied),
                       .localNetworkDenied)
        XCTAssertEqual(MideaDevice.connectionError(unreachable, unsatisfiedReason: .notAvailable),
                       .connectionFailed(unreachable.localizedDescription, posixCode: EHOSTUNREACH))
        XCTAssertEqual(MideaDevice.connectionError(unreachable),
                       .connectionFailed(unreachable.localizedDescription, posixCode: EHOSTUNREACH))
        XCTAssertEqual(MideaDevice.connectionError(.posix(.EHOSTDOWN), unsatisfiedReason: .notAvailable),
                       .connectionFailed(NWError.posix(.EHOSTDOWN).localizedDescription, posixCode: EHOSTDOWN))
    }

    /// Reconnecting can't lift a denial, so it is never retried.
    func testLocalNetworkDenialIsNotRetried() {
        XCTAssertFalse(MideaError.localNetworkDenied.isTransportFailure)
    }

    /// A refused connection still reports its POSIX code, so the app can tell it from a denial.
    func testRefusedConnectionKeepsPosixCode() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(listener, $0, length)
                _ = getsockname(listener, $0, &length)
            }
        }
        close(listener)   // nothing listens on the port any more
        let device = MideaDevice(host: "127.0.0.1", port: UInt16(bigEndian: addr.sin_port), deviceID: 1,
                                 token: token, key: Bytes(repeating: 1, count: 32),
                                 timing: .init(readTimeout: 0.3, attempts: 1, settle: 0, connectTimeout: 2))
        let result = await outcome { try await device.refresh() }
        guard case .connectionFailed(_, posixCode: let code) = mideaError(result) else {
            return XCTFail("expected connectionFailed, got \(result)")
        }
        XCTAssertEqual(code, ECONNREFUSED)
    }
}

private extension MideaError {
    var isConnectionFailed: Bool {
        if case .connectionFailed = self { return true }
        return false
    }
}
