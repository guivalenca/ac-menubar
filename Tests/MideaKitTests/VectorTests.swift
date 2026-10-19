import Foundation
import XCTest
@testable import MideaKit

/// Golden vectors generated from msmart-ng (tools/gen_vectors.py), including a state frame captured from
/// a unit and a synthetic discovery reply from a fake one.
final class VectorTests: XCTestCase {
    private var v: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Vectors", withExtension: "json"))
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func dict(_ key: String) -> [String: Any] { v[key] as! [String: Any] }
    private func bytes(_ any: Any?) -> Bytes { Bytes(hex: any as! String)! }

    func testCRC8AndChecksum() {
        let c = dict("crc8")
        let data = bytes(c["data"])
        XCTAssertEqual(Int(CRC8.calculate(data)), c["crc"] as? Int)
        XCTAssertEqual(Int(ACFrame.checksum(data)), c["checksum"] as? Int)
    }

    func testGetState() {
        XCTAssertEqual(ACFrame.getState(messageID: 0x11).hex, v["get_state"] as? String)
    }

    func testSetState() {
        for case_ in v["set_state"] as! [[String: Any]] {
            let input = case_["input"] as! [String: Any]
            var s = ACState()
            s.power = input["power_on"] as! Bool
            s.targetTemperature = (input["target_temperature"] as! NSNumber).doubleValue
            s.modeRaw = UInt8(input["operational_mode"] as! Int)
            s.fanSpeedRaw = UInt8(input["fan_speed"] as! Int)
            s.swingRaw = UInt8(input["swing_mode"] as! Int)
            s.eco = input["eco"] as! Bool
            s.turbo = input["turbo"] as! Bool
            s.sleep = input["sleep"] as! Bool
            s.targetHumidity = 40
            let frame = ACFrame.setState(s, beep: input["beep_on"] as! Bool, messageID: 0x21)
            XCTAssertEqual(frame.hex, case_["bytes"] as? String, "case \(input)")
        }
    }

    func testAESAndSign() throws {
        let a = dict("aes_ecb")
        XCTAssertEqual(try MideaCrypto.encryptECB(bytes(a["plain"])).hex, a["cipher"] as? String)
        XCTAssertEqual(try MideaCrypto.decryptECB(bytes(a["cipher"])).hex, a["plain"] as? String)
        let s = dict("sign")
        XCTAssertEqual(MideaCrypto.sign(bytes(s["data"])).hex, s["md5"] as? String)
    }

    func testUDPID() {
        let u = dict("udpid")
        let id = (u["id"] as! NSNumber).uint64Value
        XCTAssertEqual(MideaCrypto.udpid(ByteOrder.le64(id).prefix(6).map { $0 }).hex, u["little"] as? String)
        XCTAssertEqual(MideaCrypto.udpid(Bytes(ByteOrder.le64(id).prefix(6).reversed())).hex, u["big"] as? String)
    }

    func testV2Packet() throws {
        let p = dict("packet")
        let id = (p["id"] as! NSNumber).uint64Value
        let packet = try MideaPacket.encode(deviceID: id, frame: bytes(p["frame"]), timestamp: bytes(p["timestamp"]))
        XCTAssertEqual(packet.hex, p["packet"] as? String)
        XCTAssertEqual(try MideaPacket.decode(packet).hex, p["frame"] as? String)
    }

    func testV3Encoding() throws {
        let h = dict("v3_handshake")
        XCTAssertEqual(MideaV3.encodeHandshake(packetID: 0, token: bytes(h["token"])).hex, h["packet"] as? String)

        let e = dict("v3_encrypted")
        let encrypted = try MideaV3.encodeEncrypted(packetID: 5, data: bytes(e["data"]), localKey: bytes(e["local_key"]),
                                                    randomPadding: { Bytes(repeating: 0xA5, count: $0) })
        XCTAssertEqual(encrypted.hex, e["packet"] as? String)
    }

    func testV3ResponseAndStreamSplitting() throws {
        let r = dict("v3_response")
        let packet = bytes(r["packet"])
        XCTAssertEqual(try MideaV3.process(packet: packet, localKey: bytes(r["local_key"])), .payload(bytes(r["payload"])))

        // Two packets split across arbitrary chunk boundaries, with leading garbage.
        var buffer: Bytes = [0x01, 0x02]
        var out: [Bytes] = []
        let stream = packet + packet
        for chunk in stride(from: 0, to: stream.count, by: 37).map({ Bytes(stream[$0..<min($0 + 37, stream.count)]) }) {
            buffer += chunk
            out += MideaV3.extractPackets(from: &buffer)
        }
        XCTAssertEqual(out, [packet, packet])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testLocalKey() throws {
        let k = dict("local_key")
        XCTAssertEqual(try MideaV3.localKey(cloudKey: bytes(k["cloud_key"]), handshakePayload: bytes(k["handshake_payload"])).hex,
                       k["local_key"] as? String)
    }

    func testRealStateFrame() throws {
        let r = dict("state_response")
        let parsed = r["parsed"] as! [String: Any]
        let s = try XCTUnwrap(try ACFrame.parseState(frame: bytes(r["frame"])))
        XCTAssertEqual(s.power, parsed["power_on"] as? Bool)
        XCTAssertEqual(s.targetTemperature, (parsed["target_temperature"] as! NSNumber).doubleValue)
        XCTAssertEqual(Int(s.modeRaw), parsed["operational_mode"] as? Int)
        XCTAssertEqual(Int(s.fanSpeedRaw), parsed["fan_speed"] as? Int)
        XCTAssertEqual(Int(s.swingRaw), parsed["swing_mode"] as? Int)
        XCTAssertEqual(s.eco, parsed["eco"] as? Bool)
        XCTAssertEqual(s.turbo, parsed["turbo"] as? Bool)
        XCTAssertEqual(s.sleep, parsed["sleep"] as? Bool)
        XCTAssertEqual(s.indoorTemperature, (parsed["indoor_temperature"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(s.outdoorTemperature, (parsed["outdoor_temperature"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(s.displayOn, parsed["display_on"] as? Bool)
    }

    /// Synthetic reply for a fake unit, also checked against msmart-ng's parse of it.
    func testDiscoveryReply() throws {
        let r = dict("discovery_reply")
        let parsed = r["parsed"] as! [String: Any]
        let device = try MideaDiscovery.parseReply(bytes(r["packet"]), from: "192.0.2.50")
        XCTAssertEqual(device.ip, "192.0.2.50")
        XCTAssertEqual(device.id, 0x112233445566)
        XCTAssertEqual(device.port, 6444)
        XCTAssertEqual(device.version, 3)
        XCTAssertEqual(device.name, "net_ac_FAKE")
        XCTAssertEqual(device.serial, "000000000000000000000000FAKE0001")

        XCTAssertEqual(device.ip, parsed["ip"] as? String)
        XCTAssertEqual(device.id, (parsed["id"] as! NSNumber).uint64Value)
        XCTAssertEqual(Int(device.port), parsed["port"] as? Int)
        XCTAssertEqual(device.version, parsed["version"] as? Int)
        XCTAssertEqual(device.name, parsed["name"] as? String)
        XCTAssertEqual(device.serial, parsed["serial"] as? String)
    }

    func testMACNormalization() {
        XCTAssertEqual(ACConfigStore.normalizeMAC("00:00:5E:0:53:a"), "00:00:5e:00:53:0a")
    }

    /// The app no longer reads `homeRouterMACs`; files with or without it still decode, and saving
    /// keeps it.
    func testConfigWithAndWithoutRouterMACs() throws {
        let device = #"{"id": 1, "name": "Sala", "host": "192.0.2.50", "port": 6444, "token": "aa", "key": "bb"}"#
        let without = try JSONDecoder().decode(ACAppConfig.self, from: Data(#"{"devices": [\#(device)]}"#.utf8))
        XCTAssertEqual(without.homeRouterMACs, [])
        XCTAssertEqual(without.devices.first?.host, "192.0.2.50")

        let with = try JSONDecoder().decode(
            ACAppConfig.self, from: Data(#"{"homeRouterMACs": ["00:00:5e:00:53:01"], "devices": [\#(device)]}"#.utf8))
        XCTAssertEqual(with.homeRouterMACs, ["00:00:5e:00:53:01"])
        let again = try JSONDecoder().decode(ACAppConfig.self, from: JSONEncoder().encode(with))
        XCTAssertEqual(again, with)
    }
}
