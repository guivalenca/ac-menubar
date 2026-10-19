import CommonCrypto
import CryptoKit
import Foundation

/// Cryptographic primitives used by the Midea LAN protocol (ported from msmart-ng's `Security`).
public enum MideaCrypto {
    static let signKey = Bytes("xhdiwjnchekd4d512chdjx5d8e4c394D2D7S".utf8)
    static let encKey = md5(signKey)
    private static let zeroIV = Bytes(repeating: 0, count: kCCBlockSizeAES128)

    public static func md5(_ data: Bytes) -> Bytes { Bytes(Insecure.MD5.hash(data: data)) }
    public static func sha256(_ data: Bytes) -> Bytes { Bytes(SHA256.hash(data: data)) }

    /// MD5 of the packet followed by the fixed sign key.
    public static func sign(_ data: Bytes) -> Bytes { md5(data + signKey) }

    /// UDP ID used by the cloud to look up a device's token: SHA256 of the ID with its halves XORed.
    public static func udpid(_ deviceID: Bytes) -> Bytes {
        let hash = sha256(deviceID)
        return (0..<16).map { hash[$0] ^ hash[$0 + 16] }
    }

    /// AES-CBC with a zero IV and no padding (V3 transport layer).
    public static func encryptCBC(key: Bytes, _ data: Bytes) throws -> Bytes {
        try aes(CCOperation(kCCEncrypt), key: key, data: data, options: 0, iv: zeroIV)
    }

    public static func decryptCBC(key: Bytes, _ data: Bytes) throws -> Bytes {
        try aes(CCOperation(kCCDecrypt), key: key, data: data, options: 0, iv: zeroIV)
    }

    /// AES-ECB with PKCS7 padding using the fixed key (V2 packet layer).
    public static func encryptECB(_ data: Bytes) throws -> Bytes {
        try aes(CCOperation(kCCEncrypt), key: encKey, data: data,
                options: CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), iv: nil)
    }

    public static func decryptECB(_ data: Bytes) throws -> Bytes {
        try aes(CCOperation(kCCDecrypt), key: encKey, data: data,
                options: CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), iv: nil)
    }

    private static func aes(_ op: CCOperation, key: Bytes, data: Bytes, options: CCOptions, iv: Bytes?) throws -> Bytes {
        var out = Bytes(repeating: 0, count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            if let iv {
                return CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options, key, key.count, iv,
                               data, data.count, outPtr.baseAddress, outCapacity, &moved)
            }
            return CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options, key, key.count, nil,
                           data, data.count, outPtr.baseAddress, outCapacity, &moved)
        }
        guard status == kCCSuccess else { throw MideaError.crypto(status) }
        return Bytes(out.prefix(moved))
    }
}

/// CRC-8 (Dallas/Maxim, reflected polynomial 0x8C) as used in AC command payloads.
public enum CRC8 {
    static let table: Bytes = (0..<256).map { i in
        var c = UInt8(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8C : c >> 1 }
        return c
    }

    public static func calculate<S: Sequence>(_ data: S) -> UInt8 where S.Element == UInt8 {
        var crc: UInt8 = 0
        for b in data { crc = table[Int(crc ^ b)] }
        return crc
    }
}
