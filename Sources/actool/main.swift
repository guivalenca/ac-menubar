import Foundation
import MideaKit

// Developer CLI for exercising MideaKit against the real units.
//   actool discover
//   actool status [name]
//   actool on|off [name]
//   actool set [name] temp=22 mode=cool fan=auto swing=off eco=on turbo=off sleep=off beep=on

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ s: ACState) -> String {
    let t = { (v: Double?) in v.map { String(format: "%.1f°C", $0) } ?? "—" }
    return """
    ligado: \(s.power ? "sim" : "não")  modo: \(s.mode.map { "\($0)" } ?? "?\(s.modeRaw)")  alvo: \(t(s.targetTemperature))
    sala: \(t(s.indoorTemperature))  fora: \(t(s.outdoorTemperature))
    ventilação: \(s.fanSpeed.map { "\($0)" } ?? "\(s.fanSpeedRaw)")  swing: \(s.swing.map { "\($0)" } ?? "?")  eco: \(s.eco)  turbo: \(s.turbo)  sleep: \(s.sleep)
    """
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("uso: actool discover | status | on | off | set k=v…") }
args.removeFirst()

if command == "discover" {
    let devices = await MideaDiscovery.discover()
    if devices.isEmpty { print("Nenhum aparelho encontrado.") }
    for d in devices { print("\(d.name)  id=\(d.id)  \(d.ip):\(d.port)  v\(d.version)  sn=\(d.serial)") }
    exit(0)
}

let config: ACAppConfig
do { config = try ACConfigStore.load() } catch { fail("Não consegui ler \(ACConfigStore.url.path): \(error)") }

let name = args.first.flatMap { $0.contains("=") ? nil : $0 }
if name != nil { args.removeFirst() }
guard let deviceConfig = name.map({ n in config.devices.first { $0.name.lowercased() == n.lowercased() } }) ?? config.devices.first else {
    fail("Aparelho não encontrado na configuração.")
}

let device: MideaDevice
do { device = try deviceConfig.makeDevice() } catch { fail("\(error)") }

do {
    var state = try await device.refresh()
    var beep = false
    switch command {
    case "status":
        print(describe(state))
        exit(0)
    case "on", "off":
        state.power = command == "on"
    case "set":
        for pair in args {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("argumento inválido: \(pair)") }
            let (k, val) = (parts[0], parts[1].lowercased())
            let on = ["on", "1", "true", "sim"].contains(val)
            switch k {
            case "temp": state.targetTemperature = Double(val.replacingOccurrences(of: ",", with: ".")) ?? state.targetTemperature
            case "mode": state.mode = ["auto": .auto, "cool": .cool, "dry": .dry, "fan": .fanOnly][val]
            case "fan": state.fanSpeed = ["auto": .auto, "low": .low, "medium": .medium, "high": .high][val]
            case "swing": state.swing = ["off": .off, "vertical": .vertical, "horizontal": .horizontal, "both": .both][val]
            case "eco": state.eco = on
            case "turbo": state.turbo = on
            case "sleep": state.sleep = on
            case "power": state.power = on
            case "beep": beep = on
            default: fail("chave desconhecida: \(k)")
            }
        }
    default:
        fail("comando desconhecido: \(command)")
    }
    let reported = try await device.apply(state, beep: beep)
    print(describe(reported ?? state))
} catch {
    fail("Erro: \(error.localizedDescription)")
}
