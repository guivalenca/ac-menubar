import Foundation

public struct ACDeviceConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt64
    public var name: String
    public var host: String
    public var port: UInt16
    public var token: String
    public var key: String

    public init(id: UInt64, name: String, host: String, port: UInt16 = 6444, token: String, key: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.token = token
        self.key = key
    }

    public func makeDevice() throws -> MideaDevice {
        guard let token = Bytes(hex: token), let key = Bytes(hex: key) else {
            throw MideaError.authenticationFailed("token ou chave inválidos no arquivo de configuração")
        }
        return MideaDevice(host: host, port: port, deviceID: id, token: token, key: key)
    }
}

public struct ACAppConfig: Codable, Equatable, Sendable {
    /// MAC addresses of the home Wi-Fi router(s). Unused: macOS hides the ARP table from apps, so the
    /// app can't read the router's MAC. Kept so existing files decode and keep it when the app saves.
    public var homeRouterMACs: [String]
    public var devices: [ACDeviceConfig]

    public init(homeRouterMACs: [String] = [], devices: [ACDeviceConfig] = []) {
        self.homeRouterMACs = homeRouterMACs
        self.devices = devices
    }

    private enum CodingKeys: String, CodingKey {
        case homeRouterMACs, devices
    }

    /// `homeRouterMACs` may be missing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        homeRouterMACs = try container.decodeIfPresent([String].self, forKey: .homeRouterMACs) ?? []
        devices = try container.decode([ACDeviceConfig].self, forKey: .devices)
    }
}

/// Reads and writes ~/.config/ac-menubar/config.json (owner-only permissions; it holds device keys).
public enum ACConfigStore {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ac-menubar", isDirectory: true)
    }

    public static var url: URL { directory.appendingPathComponent("config.json") }

    public static func load() throws -> ACAppConfig {
        try JSONDecoder().decode(ACAppConfig.self, from: Data(contentsOf: url))
    }

    public static func save(_ config: ACAppConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Normalizes "0:0:5e:0:53:a" (as printed by arp) to "00:00:5e:00:53:0a".
    public static func normalizeMAC(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
    }
}
