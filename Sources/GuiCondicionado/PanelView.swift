import AppKit
import MideaKit
import SwiftUI

/// The menu bar panel, a Bento grid: a tall temperature slider beside power and mode, then fan and
/// air direction, then three feature toggles, between a header and a status footer.
struct PanelView: View {
    @EnvironmentObject private var store: ACStore
    @State private var onScreen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.setupError {
                Notice(symbol: "exclamationmark.triangle", title: "Configuração", message: error, warning: true)
                footer(status: false)
            } else if store.sync == .blocked {
                PanelHeader(name: store.deviceName, indoor: nil, outdoor: nil)
                LocalNetworkNotice(onRetry: store.refreshNow)
                footer(status: false)
            } else if let state = store.state {
                PanelHeader(name: store.deviceName, indoor: state.indoorTemperature, outdoor: state.outdoorTemperature)
                grid(state)
                if state.errorCode != 0 {
                    Label("O ar informou o código de erro \(state.errorCode).", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warning)
                        .padding(.horizontal, 4)
                        .padding(.top, 11)
                }
                footer(status: true)
            } else {
                PanelHeader(name: store.deviceName, indoor: nil, outdoor: nil)
                ConnectingNotice(sync: store.sync, onRetry: store.refreshNow)
                footer(status: false)
            }
        }
        .padding(Bento.padding)
        .frame(width: Bento.width)
        .background {
            // ImageRenderer draws AppKit views as a placeholder; snapshots have no window anyway.
            if Snapshot.requestedPath == nil {
                OnScreenReader { visible in
                    if onScreen != visible { onScreen = visible }
                }
            }
        }
        .environment(\.panelOnScreen, onScreen)
    }

    private func grid(_ s: ACState) -> some View {
        VStack(spacing: Bento.gap) {
            HStack(spacing: Bento.gap) {
                TemperatureSlider(value: s.targetTemperature, room: s.indoorTemperature, roomName: store.deviceName,
                                  isPowered: s.power, isEnabled: s.mode != .fanOnly,
                                  onChange: store.setTarget, onStep: store.stepTarget)
                    .frame(width: Bento.half, height: 2 * Bento.row + Bento.gap)
                VStack(spacing: Bento.gap) {
                    PowerModule(isOn: s.power, action: store.togglePower)
                    MenuModule(title: "Modo", value: Labels.mode(s.mode), help: "Escolher modo", isPowered: s.power,
                               action: { showModeMenu(s) }) {
                        Image(systemName: Labels.modeSymbol(s.mode))
                    }
                }
                .frame(width: Bento.half)
            }
            HStack(spacing: Bento.gap) {
                MenuModule(title: "Ventilação", value: Labels.fan(s.fanSpeed), help: "Escolher ventilação",
                           isPowered: s.power, action: { showFanMenu(s) }) {
                    Image(systemName: "fan")
                }
                MenuModule(title: "Direção do ar", value: Labels.swing(s.swing), help: "Escolher direção do ar",
                           isPowered: s.power, action: { showSwingMenu(s) }) {
                    Image(systemName: Labels.swingSymbol(s.swing))
                }
            }
            .frame(height: Bento.row)
            HStack(spacing: Bento.gap) {
                ToggleModule(title: "Eco", symbol: "leaf", isOn: s.eco, isPowered: s.power,
                             help: (on: "Desligar Eco", off: "Ligar Eco"), action: store.toggleEco)
                ToggleModule(title: "Turbo", symbol: "bolt", isOn: s.turbo, isPowered: s.power,
                             help: (on: "Desligar Turbo", off: "Ligar Turbo"), action: store.toggleTurbo)
                ToggleModule(title: "Dormir", symbol: "moon", isOn: s.sleep, isPowered: s.power,
                             help: (on: "Desligar modo Dormir", off: "Ligar modo Dormir"), action: store.toggleSleep)
            }
            .frame(height: Bento.row)
        }
        .frame(width: Bento.content)
    }

    private func footer(status: Bool) -> some View {
        FooterRow(sync: status ? store.sync : nil, lastUpdate: store.lastUpdate, onSettings: showSettingsMenu)
    }

    // MARK: Menus

    private func showModeMenu(_ s: ACState) {
        PopupMenu.show(Labels.modes.map { mode in
            .item(Labels.mode(mode), symbol: Labels.modeSymbol(mode), checked: s.mode == mode) { store.setMode(mode) }
        }, selectionUnderPointer: true)
    }

    private func showFanMenu(_ s: ACState) {
        PopupMenu.show(Labels.fans.map { fan in
            .item(Labels.fan(fan), checked: s.fanSpeed == fan) { store.setFan(fan) }
        }, selectionUnderPointer: true)
    }

    private func showSwingMenu(_ s: ACState) {
        PopupMenu.show(Labels.swings.map { swing in
            .item(Labels.swing(swing), symbol: Labels.swingSymbol(swing), checked: s.swing == swing) { store.setSwing(swing) }
        }, selectionUnderPointer: true)
    }

    private func showSettingsMenu() {
        PopupMenu.show([
            .item("Atualizar agora") { store.refreshNow() },
            .separator,
            .item("Bipe ao alterar", checked: store.beepEnabled) { store.beepEnabled.toggle() },
            .item("Abrir ao iniciar o Mac", checked: LoginItem.isEnabled) { LoginItem.toggle() },
            .separator,
            .item("Sair do GuiCondicionado") { NSApp.terminate(nil) },
        ])
    }
}

// MARK: - Sections

/// "Sala" on the leading side, "23° agora · lá fora 18,5°" trailing.
private struct PanelHeader: View {
    let name: String
    let indoor: Double?
    let outdoor: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.15)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let readings {
                readings
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 1)
        .padding(.bottom, 12)
    }

    private var readings: Text? {
        let outside = outdoor.map { Format.degrees($0) }
        switch (indoor, outside) {
        case (let indoor?, let outside?):
            return Text(Format.degrees(indoor)).fontWeight(.medium).foregroundStyle(Palette.strongMeta)
                + Text(" agora · lá fora \(outside)").foregroundStyle(.secondary)
        case (let indoor?, nil):
            return Text(Format.degrees(indoor)).fontWeight(.medium).foregroundStyle(Palette.strongMeta)
                + Text(" agora").foregroundStyle(.secondary)
        case (nil, let outside?):
            return Text("Lá fora \(outside)").foregroundStyle(.secondary)
        case (nil, nil):
            return nil
        }
    }
}

/// Sync status on the leading side, the settings button trailing.
private struct FooterRow: View {
    /// Nil hides the status, for full-panel notices that already explain it.
    let sync: ACStore.Sync?
    let lastUpdate: Date?
    let onSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelOnScreen) private var onScreen

    var body: some View {
        HStack(spacing: 6) {
            switch sync {
            case .idle:
                Circle().fill(Palette.footer).opacity(0.8).frame(width: 5, height: 5)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Format.updated(lastUpdate, now: context.date))
                }
            case .syncing:
                Image(systemName: "circle.fill")
                    .font(.system(size: 5.5))
                    .symbolEffect(.pulse, options: .repeating, isActive: onScreen && !reduceMotion)
                Text("Sincronizando…")
            case .offline(let message):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.warning)
                Text(message).foregroundStyle(Palette.footerStrong)
            case .blocked:
                Image(systemName: "lock.shield").foregroundStyle(Palette.warning)
                Text("Sem acesso à rede local").foregroundStyle(Palette.footerStrong)
            case nil:
                EmptyView()
            }
            Spacer(minLength: 8)
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(GlyphButtonStyle())
            // Keep the 26 pt hit area without making the footer taller than its text.
            .padding(.vertical, -7)
            .padding(.trailing, -6)
            .help("Ajustes")
            .accessibilityLabel("Ajustes")
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .foregroundStyle(Palette.footer)
        .padding(.horizontal, 4)
        .padding(.top, 11)
    }
}

/// A full-width card that stands in for the grid when there is no state to show.
private struct Notice<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var warning = false
    /// Pulses the symbol, for work in progress.
    var busy = false
    @ViewBuilder var actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelOnScreen) private var onScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Orb {
                    Image(systemName: symbol)
                        .symbolEffect(.pulse, options: .repeating, isActive: busy && onScreen && !reduceMotion)
                }
                .foregroundStyle(warning ? AnyShapeStyle(Palette.warning) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if Actions.self != EmptyView.self {
                HStack(spacing: 8) { actions }
                    .padding(.leading, Bento.orb + 12)
            }
        }
        .padding(14)
        .frame(width: Bento.content, alignment: .leading)
        .background(ModuleBackground())
        .accessibilityElement(children: .contain)
    }
}

extension Notice where Actions == EmptyView {
    init(symbol: String, title: String, message: String, warning: Bool = false, busy: Bool = false) {
        self.init(symbol: symbol, title: title, message: message, warning: warning, busy: busy) { EmptyView() }
    }
}

private struct ConnectingNotice: View {
    let sync: ACStore.Sync
    let onRetry: () -> Void

    var body: some View {
        switch sync {
        case .offline(let message):
            Notice(symbol: "wifi.exclamationmark", title: "Sem conexão", message: message, warning: true) {
                CapsuleButton(title: "Tentar de novo", action: onRetry)
            }
        default:
            Notice(symbol: "air.conditioner.horizontal", title: "Conectando…",
                   message: "Falando com o ar-condicionado.", busy: true)
        }
    }
}

/// Shown when TCP fails with EHOSTUNREACH: macOS Local Network privacy, or a VPN, blocks the LAN.
private struct LocalNetworkNotice: View {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    let onRetry: () -> Void

    var body: some View {
        Notice(symbol: "lock.shield", title: "Sem acesso à rede local",
               message: "O macOS bloqueou a conexão com o ar. Em Ajustes do Sistema → Privacidade e Segurança → Rede Local, ative o GuiCondicionado. Se uma VPN estiver ligada, desligue-a.",
               warning: true) {
            CapsuleButton(title: "Abrir Ajustes") { NSWorkspace.shared.open(Self.settingsURL) }
            CapsuleButton(title: "Tentar de novo", prominent: false, action: onRetry)
        }
    }
}

// MARK: - Labels

enum Labels {
    /// This unit only cools, so there is no Aquecer.
    static let modes: [ACMode] = [.cool, .dry, .fanOnly, .auto]
    static let fans: [ACFanSpeed] = [.auto, .low, .medium, .high]
    static let swings: [ACSwing] = [.off, .vertical, .horizontal, .both]

    static func mode(_ mode: ACMode?) -> String {
        switch mode {
        case .cool: return "Refrigerar"
        case .dry: return "Desumidificar"
        case .fanOnly: return "Ventilar"
        case .auto: return "Automático"
        case .heat: return "Aquecer"
        case .smartDry: return "Secar"
        case nil: return "—"
        }
    }

    static func modeSymbol(_ mode: ACMode?) -> String {
        switch mode {
        case .cool: return "snowflake"
        case .dry, .smartDry: return "drop"
        case .fanOnly: return "wind"
        case .heat: return "sun.max"
        case .auto, nil: return "a.circle"
        }
    }

    /// Feminine: *a ventilação*.
    static func fan(_ fan: ACFanSpeed?) -> String {
        switch fan {
        case .auto: return "Automática"
        case .silent: return "Silenciosa"
        case .low: return "Baixa"
        case .medium: return "Média"
        case .high: return "Alta"
        case .max: return "Máxima"
        case nil: return "—"
        }
    }

    /// Feminine: *a direção do ar*.
    static func swing(_ swing: ACSwing?) -> String {
        switch swing {
        case .off: return "Desligada"
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        case .both: return "Ambas"
        case nil: return "—"
        }
    }

    static func swingSymbol(_ swing: ACSwing?) -> String {
        switch swing {
        case .vertical: return "arrow.up.and.down"
        case .horizontal: return "arrow.left.and.right"
        case .both: return "arrow.up.and.down.and.arrow.left.and.right"
        case .off, nil: return "arrow.down"
        }
    }
}
