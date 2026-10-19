import AppKit
import MideaKit
import ServiceManagement
import SwiftUI

enum Format {
    /// "21" or "20,5" (Brazilian decimal comma).
    static func number(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
    }

    static func degrees(_ value: Double) -> String { number(value) + "°" }

    static func updated(_ date: Date?, now: Date) -> String {
        guard let date else { return "Aguardando o ar" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Atualizado agora" }
        let minutes = Int(seconds / 60)
        return minutes == 1 ? "Atualizado há 1 min" : "Atualizado há \(minutes) min"
    }
}

enum AppInfo {
    /// The name chosen at build time (`scripts/build-app.sh --name`), from the bundle's Info.plist.
    /// A bare binary, as in snapshots, has none.
    static let name: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "ac-menubar"
    }()
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("\(AppInfo.name): login item change failed: \(error)")
        }
    }
}

/// `ac-menubar --snapshot out.png [--dark] [--framed] [--scenario on|off|connecting|offline|permission]`
/// renders the panel with sample data and exits, before any store or scene exists (for development and
/// design reviews). `--off` is short for `--scenario off`. `--framed` draws it as a floating panel, with
/// rounded corners and a shadow on a transparent background (the README screenshots).
@MainActor
enum Snapshot {
    enum Scenario: String, CaseIterable {
        case on, off, connecting, offline, permission
    }

    static var requestedPath: String? { argument(after: "--snapshot") }

    /// Returns false, after saying why on stderr, when no image was written.
    static func render(to path: String) -> Bool {
        let args = CommandLine.arguments
        let name = argument(after: "--scenario") ?? (args.contains("--off") ? "off" : "on")
        guard let scenario = Scenario(rawValue: name) else {
            fail("unknown scenario \"\(name)\" (use \(Scenario.allCases.map(\.rawValue).joined(separator: ", ")))")
            return false
        }

        let scheme: ColorScheme = args.contains("--dark") ? .dark : .light
        let panel = PanelView()
            .environmentObject(store(for: scenario))
            .background(Color(nsColor: .windowBackgroundColor))
        let corner = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let view = Group {
            if args.contains("--framed") {
                panel
                    .clipShape(corner)
                    .overlay(corner.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                    .padding(36)
            } else {
                panel
            }
        }
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            fail("snapshot failed")
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            fail("could not write \(path): \(error.localizedDescription)")
            return false
        }
    }

    private static func store(for scenario: Scenario) -> ACStore {
        switch scenario {
        case .on:
            return ACStore(preview: sample(power: true))
        case .off:
            return ACStore(preview: sample(power: false))
        case .connecting:
            return ACStore(preview: nil, lastUpdate: nil)
        case .offline:
            return ACStore(preview: sample(power: true), sync: .offline("O ar não respondeu."),
                           lastUpdate: Date().addingTimeInterval(-5 * 60))
        case .permission:
            return ACStore(preview: sample(power: true), sync: .blocked)
        }
    }

    private static func sample(power: Bool) -> ACState {
        var state = ACState()
        state.power = power
        state.targetTemperature = 21
        state.modeRaw = ACMode.cool.rawValue
        state.fanSpeedRaw = ACFanSpeed.auto.rawValue
        state.swingRaw = ACSwing.vertical.rawValue
        state.eco = true
        state.indoorTemperature = 23
        state.outdoorTemperature = 18.5
        return state
    }

    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
