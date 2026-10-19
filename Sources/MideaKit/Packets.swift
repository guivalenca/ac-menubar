import Foundation

/// V2 "5A5A" packet: 40 byte header + AES-ECB encrypted frame + MD5 sign.
public enum MideaPacket {
    /// Each byte is a component of the UTC time: centiseconds, s, min, h, day, month, year % 100, year / 100.
    public static func timestamp(_ date: Date = Date()) -> Bytes {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let year = c.year ?? 2000
        return [UInt8((c.nanosecond ?? 0) / 10_000_000), UInt8(c.second ?? 0), UInt8(c.minute ?? 0),
                UInt8(c.hour ?? 0), UInt8(c.day ?? 1), UInt8(c.month ?? 1),
                UInt8(year % 100), UInt8(year / 100)]
    }

    public static func encode(deviceID: UInt64, frame: Bytes, timestamp: Bytes = timestamp()) throws -> Bytes {
        let encrypted = try MideaCrypto.encryptECB(frame)
        let length = 40 + encrypted.count + 16

        var packet: Bytes = [0x5A, 0x5A, 0x01, 0x11]   // start of packet, message type
        packet += ByteOrder.le16(length)
        packet += [0x20, 0x00]                          // magic
        packet += Bytes(repeating: 0, count: 4)         // message ID
        packet += timestamp
        packet += ByteOrder.le64(deviceID)
        packet += Bytes(repeating: 0, count: 12)
        packet += encrypted
        return packet + MideaCrypto.sign(packet)
    }

    public static func decode(_ data: Bytes) throws -> Bytes {
        guard data.count >= 6 else { throw MideaError.invalidPacket("curto demais") }
        guard data[0] == 0x5A, data[1] == 0x5A else { throw MideaError.invalidPacket("início desconhecido") }
        let length = Int(data[4]) | Int(data[5]) << 8
        guard length >= 56, data.count >= length else { throw MideaError.invalidPacket("truncado") }

        let packet = Bytes(data[0..<length])
        let signed = Bytes(packet[0..<(length - 16)])
        guard MideaCrypto.sign(signed) == Bytes(packet[(length - 16)...]) else {
            throw MideaError.invalidPacket("assinatura MD5 não confere")
        }
        return try MideaCrypto.decryptECB(Bytes(packet[40..<(length - 16)]))
    }
}

/// V3 "8370" transport: wraps V2 packets with an AES-CBC session key negotiated from the cloud token/key.
public enum MideaV3 {
    enum PacketType: UInt8 {
        case handshakeRequest = 0x0
        case handshakeResponse = 0x1
        case encryptedResponse = 0x3
        case encryptedRequest = 0x6
        case error = 0xF
    }

    public enum Decoded: Equatable {
        case handshake(Bytes)
        case payload(Bytes)
    }

    static func header(length: Int, typeByte: UInt8) -> Bytes {
        [0x83, 0x70] + ByteOrder.be16(length) + [0x20, typeByte]
    }

    public static func encodeHandshake(packetID: UInt16, token: Bytes) -> Bytes {
        header(length: token.count, typeByte: PacketType.handshakeRequest.rawValue)
            + ByteOrder.be16(Int(packetID)) + token
    }

    public static func encodeEncrypted(packetID: UInt16, data: Bytes, localKey: Bytes,
                                       randomPadding: (Int) -> Bytes = MideaV3.randomBytes) throws -> Bytes {
        // The 2 byte packet ID counts for alignment but not for the length field.
        let remainder = (data.count + 2) % 16
        let pad = remainder == 0 ? 0 : 16 - remainder
        let hdr = header(length: data.count + pad + 32,
                         typeByte: UInt8(pad << 4) | PacketType.encryptedRequest.rawValue)
        let payload = ByteOrder.be16(Int(packetID)) + data + randomPadding(pad)
        let hash = MideaCrypto.sha256(hdr + payload)
        return hdr + (try MideaCrypto.encryptCBC(key: localKey, payload)) + hash
    }

    public static func randomBytes(_ count: Int) -> Bytes {
        (0..<count).map { _ in UInt8.random(in: 0...255) }
    }

    /// Pulls complete 8370 packets out of a TCP stream buffer, leaving any partial packet in place.
    public static func extractPackets(from buffer: inout Bytes) -> [Bytes] {
        var packets: [Bytes] = []
        while !buffer.isEmpty {
            guard let start = findStart(in: buffer) else {
                // Keep a trailing 0x83 in case the next chunk starts with 0x70.
                buffer = buffer.last == 0x83 ? [0x83] : []
                return packets
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 6 else { return packets }
            let total = (Int(buffer[2]) << 8 | Int(buffer[3])) + 8
            guard buffer.count >= total else { return packets }
            packets.append(Bytes(buffer[0..<total]))
            buffer.removeFirst(total)
        }
        return packets
    }

    private static func findStart(in buffer: Bytes) -> Int? {
        guard buffer.count >= 2 else { return nil }
        for i in 0..<(buffer.count - 1) where buffer[i] == 0x83 && buffer[i + 1] == 0x70 {
            return i
        }
        return nil
    }

    public static func process(packet: Bytes, localKey: Bytes?) throws -> Decoded {
        guard packet.count >= 8, packet[0] == 0x83, packet[1] == 0x70 else {
            throw MideaError.invalidPacket("início de pacote V3 inválido")
        }
        guard packet[4] == 0x20 else { throw MideaError.invalidPacket("byte mágico inválido") }

        switch PacketType(rawValue: packet[5] & 0xF) {
        case .encryptedResponse:
            guard let localKey else { throw MideaError.notConnected }
            guard packet.count >= 6 + 16 + 32 else { throw MideaError.invalidPacket("resposta curta") }
            let hdr = Bytes(packet[0..<6])
            let decrypted = try MideaCrypto.decryptCBC(key: localKey, Bytes(packet[6..<(packet.count - 32)]))
            guard MideaCrypto.sha256(hdr + decrypted) == Bytes(packet[(packet.count - 32)...]) else {
                throw MideaError.invalidPacket("SHA256 não confere")
            }
            let pad = Int(hdr[5] >> 4)
            guard decrypted.count >= 2 + pad else { throw MideaError.invalidPacket("padding inválido") }
            return .payload(Bytes(decrypted[2..<(decrypted.count - pad)]))
        case .handshakeResponse:
            return .handshake(Bytes(packet[8...]))
        case .error:
            throw MideaError.protocolError("o ar recusou o pedido")
        default:
            throw MideaError.invalidPacket("tipo inesperado \(packet[5] & 0xF)")
        }
    }

    /// Derives the session key from the handshake response and the cloud key.
    public static func localKey(cloudKey: Bytes, handshakePayload data: Bytes) throws -> Bytes {
        guard data.count == 64 else { throw MideaError.authenticationFailed("resposta do handshake com tamanho errado") }
        let decrypted = try MideaCrypto.decryptCBC(key: cloudKey, Bytes(data[0..<32]))
        guard MideaCrypto.sha256(decrypted) == Bytes(data[32..<64]) else {
            throw MideaError.authenticationFailed("token ou chave incorretos")
        }
        return zip(decrypted, cloudKey).map { $0 ^ $1 }
    }
}
