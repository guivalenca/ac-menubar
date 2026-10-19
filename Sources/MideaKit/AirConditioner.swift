import Foundation

/// Operational modes (raw values from the protocol).
public enum ACMode: UInt8, CaseIterable, Sendable {
    case auto = 1, cool = 2, dry = 3, heat = 4, fanOnly = 5, smartDry = 6
}

/// Fan speeds. The protocol carries a 0–100 value or 102 for auto.
public enum ACFanSpeed: UInt8, CaseIterable, Sendable {
    case silent = 20, low = 40, medium = 60, high = 80, max = 100, auto = 102
}

public enum ACSwing: UInt8, CaseIterable, Sendable {
    case off = 0x0, horizontal = 0x3, vertical = 0xC, both = 0xF
}

/// Full device state as reported by a 0xC0 state response. Raw values are kept so that
/// sending it back in a SetState command never clobbers fields the app doesn't expose.
public struct ACState: Equatable, Sendable {
    public var power = false
    public var targetTemperature = 25.0
    public var modeRaw: UInt8 = ACMode.cool.rawValue
    public var fanSpeedRaw: UInt8 = ACFanSpeed.auto.rawValue
    public var swingRaw: UInt8 = ACSwing.off.rawValue
    public var eco = false
    public var turbo = false
    public var sleep = false
    public var fahrenheit = false
    public var indoorTemperature: Double?
    public var outdoorTemperature: Double?
    public var displayOn = true
    public var filterAlert = false
    public var errorCode: UInt8 = 0
    public var followMe = false
    public var purifier = false
    public var freezeProtection = false
    public var targetHumidity: UInt8?
    public var auxHeat = false
    public var independentAuxHeat = false

    public init() {}

    public var mode: ACMode? {
        get { ACMode(rawValue: modeRaw) }
        set { if let newValue { modeRaw = newValue.rawValue } }
    }

    public var fanSpeed: ACFanSpeed? {
        get { ACFanSpeed(rawValue: fanSpeedRaw) }
        set { if let newValue { fanSpeedRaw = newValue.rawValue } }
    }

    public var swing: ACSwing? {
        get { ACSwing(rawValue: swingRaw) }
        set { if let newValue { swingRaw = newValue.rawValue } }
    }
}

/// AA-framed messages with CRC'd payloads (ported from msmart-ng's frame.py and AC/command.py).
public enum ACFrame {
    static let deviceType: UInt8 = 0xAC
    static let controlSource: UInt8 = 0x2
    static let frameControl: UInt8 = 0x02
    static let frameQuery: UInt8 = 0x03

    public static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        var sum = 0
        for b in bytes { sum &+= Int(b) }
        return UInt8(truncatingIfNeeded: -sum)
    }

    static func build(frameType: UInt8, data: Bytes) -> Bytes {
        var frame = Bytes(repeating: 0, count: 10)
        frame[0] = 0xAA
        frame[1] = UInt8(truncatingIfNeeded: data.count + 10)
        frame[2] = deviceType
        frame[9] = frameType
        frame += data
        frame.append(checksum(frame[1...]))
        return frame
    }

    static func command(_ data: Bytes, frameType: UInt8, messageID: UInt8) -> Bytes {
        let payload = data + [messageID]
        return build(frameType: frameType, data: payload + [CRC8.calculate(payload)])
    }

    public static func getState(messageID: UInt8) -> Bytes {
        command([0x41, 0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00,
                 0x02,                                   // indoor temperature request
                 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                 0x03],
                frameType: frameQuery, messageID: messageID)
    }

    public static func setState(_ s: ACState, beep: Bool, messageID: UInt8) -> Bytes {
        // Int(_:) traps on NaN, infinity and huge values.
        let target = s.targetTemperature.isFinite ? min(max(s.targetTemperature, 16), 30) : 25
        let integral = Int(target)
        let fractional = target - Double(integral)

        var temperature: UInt8
        let temperatureAlt: UInt8
        if (17...30).contains(integral) {
            temperature = UInt8((integral - 16) & 0xF)
            temperatureAlt = 0
        } else {
            temperature = 0
            temperatureAlt = UInt8((integral - 12) & 0x1F)
        }
        if fractional > 0 { temperature |= 0x10 }

        let mode = (s.modeRaw & 0x7) << 5
        let swing = 0x30 | (s.swingRaw & 0x3F)
        let ecoByte: UInt8 = (s.eco ? 0x80 : 0) | (s.purifier ? 0x20 : 0) | (s.auxHeat ? 0x08 : 0)
        let sleepByte: UInt8 = (s.sleep ? 0x01 : 0) | (s.turbo ? 0x02 : 0) | (s.fahrenheit ? 0x04 : 0)
        let followByte: UInt8 = (s.followMe ? 0x80 : 0) | (s.turbo ? 0x20 : 0)

        return command([
            0x40,
            controlSource | (beep ? 0x40 : 0) | (s.power ? 0x1 : 0),
            temperature | mode,
            s.fanSpeedRaw,
            0x7F, 0x7F, 0x00,                            // timers
            swing,
            followByte,
            ecoByte,
            sleepByte,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            temperatureAlt,
            (s.targetHumidity ?? 40) & 0x7F,
            0x00,
            s.freezeProtection ? 0x80 : 0,
            s.independentAuxHeat ? 0x08 : 0,
            0x00,
        ], frameType: frameControl, messageID: messageID)
    }

    /// Validates a frame and returns the state if it is a 0xC0 state response, nil for other responses.
    public static func parseState(frame: Bytes) throws -> ACState? {
        guard frame.count >= 13 else { throw MideaError.invalidFrame("curta demais") }
        guard checksum(frame[1..<(frame.count - 1)]) == frame[frame.count - 1] else {
            throw MideaError.invalidFrame("checksum não confere")
        }
        guard frame[2] == deviceType else { throw MideaError.invalidFrame("não é um ar-condicionado") }
        guard frame[10] == 0xC0 else { return nil }

        // Payload with its trailing CRC (some devices use a checksum instead).
        let withCRC = frame[10..<(frame.count - 1)]
        let body = Bytes(withCRC.dropLast())
        let received = withCRC.last!
        guard CRC8.calculate(body) == received || checksum(body) == received else {
            throw MideaError.invalidFrame("CRC não confere")
        }
        return try parseStateBody(body)
    }

    static func parseStateBody(_ p: Bytes) throws -> ACState {
        guard p.count >= 17 else { throw MideaError.invalidFrame("estado curto demais") }
        var s = ACState()
        s.power = p[1] & 0x1 != 0
        s.targetTemperature = Double(p[2] & 0xF) + 16 + (p[2] & 0x10 != 0 ? 0.5 : 0)
        s.modeRaw = (p[2] >> 5) & 0x7
        s.fanSpeedRaw = p[3] & 0x7F
        s.swingRaw = p[7] & 0xF
        s.turbo = p[8] & 0x20 != 0 || p[10] & 0x2 != 0
        s.independentAuxHeat = p[8] & 0x40 != 0
        s.followMe = p[8] & 0x80 != 0
        s.eco = p[9] & 0x10 != 0
        s.purifier = p[9] & 0x20 != 0
        s.auxHeat = p[9] & 0x08 != 0
        s.sleep = p[10] & 0x1 != 0
        s.fahrenheit = p[10] & 0x4 != 0
        s.indoorTemperature = temperature(p[11], decimals: Double(p[15] & 0xF) / 10, fahrenheit: s.fahrenheit)
        s.outdoorTemperature = temperature(p[12], decimals: Double(p[15] >> 4) / 10, fahrenheit: s.fahrenheit)

        let alt = p[13] & 0x1F
        if alt != 0 {
            s.targetTemperature = Double(alt) + 12 + (p[2] & 0x10 != 0 ? 0.5 : 0)
        }
        s.filterAlert = p[13] & 0x20 != 0
        s.displayOn = p[14] != 0x70
        s.errorCode = p[16]
        if p.count >= 20 { s.targetHumidity = p[19] & 0x7F }
        if p.count >= 22 { s.freezeProtection = p[21] & 0x80 != 0 }
        return s
    }

    /// Temperature decoding lifted (via msmart-ng) from dudanov/MideaUART.
    static func temperature(_ data: UInt8, decimals: Double, fahrenheit: Bool) -> Double? {
        guard data != 0xFF else { return nil }
        let t = (Double(data) - 50) / 2
        let whole = Double(Int(t))
        if !fahrenheit && decimals != 0 { return whole + (t >= 0 ? decimals : -decimals) }
        if decimals >= 0.5 { return whole + (t >= 0 ? 0.5 : -0.5) }
        return t
    }
}
