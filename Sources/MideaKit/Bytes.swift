import Foundation

public typealias Bytes = [UInt8]

extension Array where Element == UInt8 {
    /// Decodes a hex string ("0a1b…"). Returns nil on odd length or invalid characters.
    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Bytes()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Self.nibble(chars[i]), let lo = Self.nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}

enum ByteOrder {
    static func le16(_ v: Int) -> Bytes { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func be16(_ v: Int) -> Bytes { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func le64(_ v: UInt64) -> Bytes { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    static func le<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }
}

public enum MideaError: Error, LocalizedError, Equatable {
    case crypto(Int32)
    case invalidPacket(String)
    case invalidFrame(String)
    case protocolError(String)
    case authenticationFailed(String)
    case connectionFailed(String, posixCode: Int32?)
    case connectionClosed
    case notConnected
    case timeout
    case noStateResponse
    /// `disconnect()` was called while the request was in flight.
    case closedByClient
    /// macOS refused the connection because the app lacks Local Network access (the path's
    /// `unsatisfiedReason` was `.localNetworkDenied`).
    case localNetworkDenied

    public var errorDescription: String? {
        switch self {
        case .crypto(let s): return "Erro de criptografia (\(s))."
        case .invalidPacket(let m): return "Pacote inválido: \(m)"
        case .invalidFrame(let m): return "Resposta inválida: \(m)"
        case .protocolError(let m): return "Erro de protocolo: \(m)"
        case .authenticationFailed(let m): return "Falha na autenticação: \(m)"
        case .connectionFailed(let m, _): return "Não foi possível conectar: \(m)"
        case .connectionClosed: return "A conexão com o ar foi encerrada."
        case .notConnected: return "Sem conexão com o ar."
        case .timeout: return "O ar não respondeu a tempo."
        case .noStateResponse: return "O ar não enviou o estado."
        case .closedByClient: return "A conexão com o ar foi encerrada pelo app."
        case .localNetworkDenied: return "O macOS bloqueou o acesso à rede local."
        }
    }
}
