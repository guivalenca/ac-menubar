import Foundation
import XCTest
@testable import MideaKit

/// Random and crafted inputs that must never trap.
final class FuzzTests: XCTestCase {
    func rand(_ n: Int) -> Bytes { MideaV3.randomBytes(n) }

    func testParseReplyNoCrash() throws {
        // Crafted V2/V3 replies whose encrypted info has every length 0...120 and a huge name length.
        for len in 0...120 {
            var info = rand(len)
            if len > 40 { info[40] = 0xFF }
            let enc = try MideaCrypto.encryptECB(info)
            var p = rand(40) + enc + rand(16)
            p[0] = 0x5A
            p[1] = 0x5A
            _ = try? MideaDiscovery.parseReply(p, from: "1.2.3.4")
            let v3 = [0x83, 0x70] + rand(6) + p + rand(16)
            _ = try? MideaDiscovery.parseReply(v3, from: "1.2.3.4")
        }
        for _ in 0..<5000 {
            var r = rand(Int.random(in: 0...300))
            if r.count >= 2, Bool.random() {
                r[0] = 0x83; r[1] = 0x70
            } else if r.count >= 2 {
                r[0] = 0x5A; r[1] = 0x5A
            }
            _ = try? MideaDiscovery.parseReply(r, from: "1.2.3.4")
        }
    }

    func testParseStateEveryBodyLength() {
        for bodyLen in 0...40 {
            let body: Bytes = [0xC0] + rand(bodyLen)
            let withCRC = body + [CRC8.calculate(body)]
            var frame: Bytes = [0xAA, UInt8(truncatingIfNeeded: withCRC.count + 10), 0xAC, 0, 0, 0, 0, 0, 0, 0x03] + withCRC
            frame.append(ACFrame.checksum(frame[1...]))
            _ = try? ACFrame.parseState(frame: frame)
        }
        for _ in 0..<5000 { _ = try? ACFrame.parseState(frame: rand(Int.random(in: 0...60))) }
    }

    func testProcessAndDecodeNoCrash() {
        let key = rand(16)
        for _ in 0..<5000 {
            var p = rand(Int.random(in: 0...200))
            if p.count >= 6 {
                p[0] = 0x83; p[1] = 0x70; p[4] = 0x20
                p[5] = [0x01, 0x03, 0x0F, 0xF3, 0x63][Int.random(in: 0...4)]
            }
            _ = try? MideaV3.process(packet: p, localKey: key)
            var q = rand(Int.random(in: 0...200))
            if q.count >= 6 { q[0] = 0x5A; q[1] = 0x5A; q[4] = UInt8.random(in: 0...200); q[5] = 0 }
            _ = try? MideaPacket.decode(q)
        }
    }

    func testExtractPacketsTerminatesAndStaysBounded() {
        var buffer: Bytes = []
        var maxSeen = 0
        for _ in 0..<20000 {
            var chunk = rand(Int.random(in: 1...64))
            if Bool.random(), chunk.count >= 4 { chunk[0] = 0x83; chunk[1] = 0x70 }
            buffer += chunk
            _ = MideaV3.extractPackets(from: &buffer)
            maxSeen = max(maxSeen, buffer.count)
        }
        XCTAssertLessThanOrEqual(maxSeen, 0xFFFF + 8 + 64)
    }

    /// Out of range or non-finite targets are clamped instead of trapping in Int(_:).
    func testSetStateClampsTemperature() {
        func frame(_ target: Double) -> Bytes {
            var s = ACState()
            s.targetTemperature = target
            return ACFrame.setState(s, beep: false, messageID: 1)
        }
        XCTAssertEqual(frame(.nan), frame(25))
        XCTAssertEqual(frame(.infinity), frame(25))
        XCTAssertEqual(frame(-.infinity), frame(25))
        XCTAssertEqual(frame(.greatestFiniteMagnitude), frame(30))
        XCTAssertEqual(frame(-.greatestFiniteMagnitude), frame(16))
        XCTAssertEqual(frame(31), frame(30))
        XCTAssertEqual(frame(15.5), frame(16))
        XCTAssertNotEqual(frame(24.5), frame(24), "in-range halves still encode")
    }
}
