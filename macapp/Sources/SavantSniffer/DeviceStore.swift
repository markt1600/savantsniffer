import Foundation
import Network
import Combine

@MainActor
final class DeviceStore: ObservableObject {
    @Published var map: DeviceMap
    @Published var lastRunLog: [String] = []

    init() {
        if let loaded = DeviceStore.loadFromDisk() {
            map = loaded
        } else if let seed = DeviceStore.loadSeed() {
            map = seed
        } else {
            map = DeviceMap(system: nil, processor: nil, savantHost: nil, accessOK: nil,
                            source: "empty", areas: [], customMacros: [])
        }
    }

    // MARK: - persistence
    static func loadFromDisk() -> DeviceMap? {
        guard let data = try? Data(contentsOf: AppPaths.deviceMap) else { return nil }
        return try? JSONDecoder().decode(DeviceMap.self, from: data)
    }
    static func loadSeed() -> DeviceMap? {
        guard let url = Bundle.module.url(forResource: "layout.seed", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DeviceMap.self, from: data)
    }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(map) { try? data.write(to: AppPaths.deviceMap) }
    }

    /// Merge the bundled scaffold, never clobbering captured values. Returns counts.
    @discardableResult
    func mergeSeed() -> (areas: Int, keypads: Int, buttons: Int) {
        guard let seed = DeviceStore.loadSeed() else { return (0,0,0) }
        var added = (areas: 0, keypads: 0, buttons: 0)
        if map.system == nil { map.system = seed.system }
        if map.source == nil { map.source = seed.source }
        for sArea in seed.areas {
            guard let ai = map.areas.firstIndex(where: { $0.name == sArea.name }) else {
                map.areas.append(sArea); added.areas += 1; continue
            }
            for sKp in sArea.keypads {
                guard let ki = map.areas[ai].keypads.firstIndex(where: { $0.name == sKp.name }) else {
                    map.areas[ai].keypads.append(sKp); added.keypads += 1; continue
                }
                for sBtn in sKp.buttons {
                    if !map.areas[ai].keypads[ki].buttons.contains(where: { $0.label == sBtn.label }) {
                        map.areas[ai].keypads[ki].buttons.append(sBtn); added.buttons += 1
                    }
                }
            }
        }
        save()
        return added
    }

    // MARK: - labelling from a live event
    /// Associate a physical press/level event with a mapped button (by area/keypad/label).
    func recordPress(area: String, keypad: String, buttonLabel: String,
                     lutronKeypadID: Int, buttonNumber: Int) {
        guard let ai = map.areas.firstIndex(where: { $0.name == area }) else { return }
        guard let ki = map.areas[ai].keypads.firstIndex(where: { $0.name == keypad }) else { return }
        map.areas[ai].keypads[ki].lutronID = lutronKeypadID
        if let bi = map.areas[ai].keypads[ki].buttons.firstIndex(where: { $0.label == buttonLabel }) {
            map.areas[ai].keypads[ki].buttons[bi].button = buttonNumber
        }
        save()
    }

    func recordMacroEffect(area: String, keypad: String, buttonLabel: String,
                           effect: [DeviceMap.Effect]) {
        guard let ai = map.areas.firstIndex(where: { $0.name == area }),
              let ki = map.areas[ai].keypads.firstIndex(where: { $0.name == keypad }),
              let bi = map.areas[ai].keypads[ki].buttons.firstIndex(where: { $0.label == buttonLabel })
        else { return }
        map.areas[ai].keypads[ki].buttons[bi].effect = effect
        save()
    }

    func markSavantCaptured(area: String, keypad: String, buttonLabel: String, note: String) {
        guard let ai = map.areas.firstIndex(where: { $0.name == area }),
              let ki = map.areas[ai].keypads.firstIndex(where: { $0.name == keypad }),
              let bi = map.areas[ai].keypads[ki].buttons.firstIndex(where: { $0.label == buttonLabel })
        else { return }
        map.areas[ai].keypads[ki].buttons[bi].savantCaptured = true
        map.areas[ai].keypads[ki].buttons[bi].savantNote = note
        save()
    }

    // MARK: - coverage
    struct Coverage { var captured: Int; var identified: Int; var pending: Int; var total: Int
        var fraction: Double { total == 0 ? 0 : Double(captured) / Double(total) } }

    func coverage(for area: DeviceMap.Area) -> Coverage {
        var c = Coverage(captured: 0, identified: 0, pending: 0, total: 0)
        for kp in area.keypads {
            let idKnown = kp.lutronID != nil
            for b in kp.buttons {
                c.total += 1
                switch b.status(keypadIdentified: idKnown) {
                case .captured: c.captured += 1
                case .identified: c.identified += 1
                case .pending: c.pending += 1
                }
            }
        }
        return c
    }

    func overallCoverage() -> Coverage {
        var c = Coverage(captured: 0, identified: 0, pending: 0, total: 0)
        for a in map.areas {
            let ac = coverage(for: a)
            c.captured += ac.captured; c.identified += ac.identified
            c.pending += ac.pending; c.total += ac.total
        }
        return c
    }

    // MARK: - custom macros
    func addMacro(_ m: CustomMacro) { map.customMacros = (map.customMacros ?? []) + [m]; save() }
    func deleteMacro(_ id: UUID) { map.customMacros?.removeAll { $0.id == id }; save() }

    /// Run a custom macro. `confirmed` must be true (observe-first). LIP steps go
    /// through the gated client; savant steps replay a captured command over TCP.
    func runMacro(_ macro: CustomMacro, using client: LIPClient, confirmed: Bool) async {
        guard confirmed else { return }
        lastRunLog = ["Running \(macro.name)…"]
        for step in macro.steps {
            switch step.type {
            case .output, .press:
                if let cmd = CustomMacro.lipCommand(for: step) {
                    let ok = client.sendControl(cmd, confirmed: true)
                    lastRunLog.append((ok ? "sent " : "blocked ") + cmd)
                }
            case .delay:
                let ms = step.delayMs ?? 300
                lastRunLog.append("wait \(ms)ms")
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            case .savant:
                if let host = step.savantHost, let port = step.savantPort, let payload = step.savantPayload {
                    Self.sendRawTCP(host: host, port: UInt16(port), payload: payload)
                    lastRunLog.append("savant → \(host):\(port)")
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000) // gentle pacing between steps
        }
        lastRunLog.append("Done.")
    }

    static func sendRawTCP(host: String, port: UInt16, payload: String) {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.stateUpdateHandler = { st in
            if case .ready = st {
                let data = payload.replacingOccurrences(of: "\\r", with: "\r")
                                  .replacingOccurrences(of: "\\n", with: "\n")
                                  .data(using: .utf8) ?? Data()
                conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
            }
            if case .failed = st { conn.cancel() }
        }
        conn.start(queue: .global())
    }
}
