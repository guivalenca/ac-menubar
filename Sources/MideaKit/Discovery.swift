import Darwin
import Foundation

public struct DiscoveredDevice: Equatable, Sendable {
    public let ip: String
    public let port: UInt16
    public let id: UInt64
    public let name: String
    public let serial: String
    public let version: Int
}

/// UDP broadcast discovery on ports 6445/20086 (ported from msmart-ng's discover.py).
public enum MideaDiscovery {
    static let message: Bytes = [
        0x5a, 0x5a, 0x01, 0x11, 0x48, 0x00, 0x92, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x7f, 0x75, 0xbd, 0x6b, 0x3e, 0x4f, 0x8b, 0x76,
        0x2e, 0x84, 0x9c, 0x6e, 0x57, 0x8d, 0x65, 0x90,
        0x03, 0x6e, 0x9d, 0x43, 0x42, 0xa5, 0x0f, 0x1f,
        0x56, 0x9e, 0xb8, 0xec, 0x91, 0x8e, 0x92, 0xe5,
    ]

    public static func parseReply(_ reply: Bytes, from ip: String) throws -> DiscoveredDevice {
        var data = reply
        let version: Int
        if data.starts(with: [0x83, 0x70]) {
            version = 3
            guard data.count > 8 + 16 else { throw MideaError.invalidPacket("resposta de descoberta curta") }
            data = Bytes(data[8..<(data.count - 16)])
        } else if data.starts(with: [0x5A, 0x5A]) {
            version = 2
        } else {
            throw MideaError.invalidPacket("aparelho V1 não suportado")
        }
        guard data.count > 40 + 16 else { throw MideaError.invalidPacket("resposta de descoberta curta") }

        let id = ByteOrder.le(data[20..<26])
        let info = try MideaCrypto.decryptECB(Bytes(data[40..<(data.count - 16)]))
        guard info.count > 41 else { throw MideaError.invalidPacket("dados de descoberta curtos") }

        let port = UInt16(info[4]) | UInt16(info[5]) << 8
        let serial = String(decoding: info[8..<40], as: UTF8.self)
        let nameLength = Int(info[40])
        let nameEnd = min(41 + nameLength, info.count)
        let name = String(decoding: info[41..<nameEnd], as: UTF8.self)
        return DiscoveredDevice(ip: ip, port: port, id: id, name: name, serial: serial, version: version)
    }

    /// Broadcasts on every active IPv4 interface and collects replies for `timeout` seconds.
    public static func discover(timeout: TimeInterval = 3) async -> [DiscoveredDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: discoverBlocking(timeout: timeout))
            }
        }
    }

    static let debug = ProcessInfo.processInfo.environment["MIDEA_DEBUG"] != nil

    static func discoverBlocking(timeout: TimeInterval) -> [DiscoveredDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // 255.255.255.255 fails when a VPN owns the default route, so target each subnet's broadcast address.
        let targets = broadcastAddresses() + ["255.255.255.255"]
        func broadcast() {
            for target in targets {
                for port in [6445, 20086] {
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = in_port_t(UInt16(port).bigEndian)
                    inet_pton(AF_INET, target, &addr.sin_addr)
                    let sent = message.withUnsafeBytes { buf in
                        withUnsafePointer(to: &addr) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    if debug { print("sendto \(target):\(port) -> \(sent) errno \(errno)") }
                }
            }
        }

        var found: [String: DiscoveredDevice] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Bytes(repeating: 0, count: 2048)
        // Units occasionally ignore a single broadcast, so repeat it a few times (as msmart-ng does).
        var nextBroadcast = Date.distantPast
        var broadcastsLeft = 3
        while Date() < deadline {
            if broadcastsLeft > 0, Date() >= nextBroadcast {
                broadcast()
                broadcastsLeft -= 1
                nextBroadcast = Date().addingTimeInterval(0.6)
            }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &fromLen)
                    }
                }
            }
            if debug && n != -1 { print("recv \(n)") }
            guard n > 0 else { continue }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)
            guard found[ip] == nil else { continue }
            if let device = try? parseReply(Bytes(buffer[0..<n]), from: ip) {
                found[ip] = device
            }
        }
        return Array(found.values)
    }

    static func broadcastAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let dst = ptr.pointee.ifa_dstaddr else { continue }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                inet_ntop(AF_INET, &a, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: ipBuf)
            if !ip.isEmpty, !result.contains(ip) { result.append(ip) }
        }
        return result
    }
}
