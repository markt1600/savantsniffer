import Foundation
import Network
import Combine

@MainActor
final class DeviceStore: ObservableObject {
    @Published var map: DeviceMap
    @Published var lastRunLog: [String] = []
    @Published var recentLabels: [String] = []

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

    /// Merge the bundled scaffold, never clobbering captured values.
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
                for sBtn in sKp.buttons where !map.areas[ai].keypads[ki].buttons.contains(where: { $0.label == sBtn.label }) {
                    map.areas[ai].keypads[ki].buttons.append(sBtn); added.buttons += 1
                }
            }
        }
        save()
        return added
    }

    // MARK: - labelling from live events

    func recordPress(area: String, keypad: String, buttonLabel: String,
                     lutronKeypadID: Int, buttonNumber: Int) {
        guard let ai = map.areas.firstIndex(where: { $0.name == area }),
              let ki = map.areas[ai].keypads.firstIndex(where: { $0.name == keypad }) else { return }
        map.areas[ai].keypads[ki].lutronID = lutronKeypadID
        if let bi = map.areas[ai].keypads[ki].buttons.firstIndex(where: { $0.label == buttonLabel }) {
            map.areas[ai].keypads[ki].buttons[bi].button = buttonNumber
            noteRecent("\(area) · \(buttonLabel)", "keypad \(lutronKeypadID) · btn \(buttonNumber)")
        }
        save()
    }

    func recordMacroEffect(area: String, keypad: String, buttonLabel: String, effect: [DeviceMap.Effect]) {
        guard let ai = map.areas.firstIndex(where: { $0.name == area }),
              let ki = map.areas[ai].keypads.firstIndex(where: { $0.name == keypad }),
              let bi = map.areas[ai].keypads[ki].buttons.firstIndex(where: { $0.label == buttonLabel })
        else { return }
        map.areas[ai].keypads[ki].buttons[bi].effect = effect
        if map.areas[ai].keypads[ki].buttons[bi].kind == "output" && effect.count > 1 {
            map.areas[ai].keypads[ki].buttons[bi].kind = "macro"
        }
        noteRecent("\(area) · \(buttonLabel)", "macro · \(effect.count) loads")
        save()
    }

    func markSavantCaptured(area: String, keypad: String, buttonLabel: String, note: String,
                            zones: [String] = [], source: String? = nil) {
        guard let ai = map.areas.firstIndex(where: { $0.name == area }),
              let ki = map.areas[ai].keypads.firstIndex(where: { $0.name == keypad }),
              let bi = map.areas[ai].keypads[ki].buttons.firstIndex(where: { $0.label == buttonLabel })
        else { return }
        // "Captured" on the Savant side means we know what it does (zones/source or a
        // recorded command); a bare press with nothing known stays partial.
        let known = !zones.isEmpty || (source?.isEmpty == false)
        map.areas[ai].keypads[ki].buttons[bi].savantCaptured = known
        map.areas[ai].keypads[ki].buttons[bi].savantNote = note
        if !zones.isEmpty { map.areas[ai].keypads[ki].buttons[bi].audioZones = zones }
        if let src = source, !src.isEmpty { map.areas[ai].keypads[ki].buttons[bi].audioSource = src }
        noteRecent("\(area) · \(buttonLabel)", known ? "audio · " + zones.joined(separator: ", ") : "integration · Savant side pending")
        save()
    }

    /// Add (or update) a named load in an area. One entry per Lutron id.
    func addOutput(area: String, name: String, lutronID: Int, kind: String) {
        guard let ai = map.areas.firstIndex(where: { $0.name == area }) else { return }
        if let oi = map.areas[ai].outputs.firstIndex(where: { $0.lutronID == lutronID }) {
            map.areas[ai].outputs[oi].name = name
            map.areas[ai].outputs[oi].kind = kind
        } else {
            map.areas[ai].outputs.append(DeviceMap.Output(name: name, lutronID: lutronID, kind: kind))
        }
        noteRecent("\(area) · \(name)", "output id \(lutronID) · \(kind)")
        save()
    }

    private func noteRecent(_ title: String, _ detail: String) {
        recentLabels.insert("\(title)|\(detail)", at: 0)
        if recentLabels.count > 8 { recentLabels.removeLast(recentLabels.count - 8) }
    }

    // MARK: - LEAP device tree import

    struct LEAPTree: Codable {
        struct A: Codable { var id: String; var name: String }
        struct D: Codable { var id: String; var name: String; var type: String?; var model: String?; var area: String?; var zone: String?; var level: Double? }
        struct B: Codable { var id: String; var parent: String; var number: Int?; var name: String? }
        var areas: [A]; var devices: [D]; var buttons: [B]
    }

    /// Fill the map from the processor's own tree: every room, keypad, button and
    /// load with the dealer's names and real ids. Intents from the button schedule
    /// are carried over where the names match. Returns a summary.
    @discardableResult
    func importLEAPTree(_ data: Data) -> String {
        guard let tree = try? JSONDecoder().decode(LEAPTree.self, from: data) else { return "could not parse the device tree" }
        let seed = DeviceStore.loadSeed()
        var seedByKey: [String: DeviceMap.Button] = [:]
        var seedByLabel: [String: [DeviceMap.Button]] = [:]
        for a in seed?.areas ?? [] {
            for k in a.keypads { for b in k.buttons {
                seedByKey[a.name.lowercased() + "|" + b.label.lowercased()] = b
                seedByLabel[b.label.lowercased(), default: []].append(b)
            } }
        }
        func intentFor(area: String, label: String) -> DeviceMap.Button? {
            if let b = seedByKey[area.lowercased() + "|" + label.lowercased()] { return b }
            if let list = seedByLabel[label.lowercased()], list.count == 1 { return list[0] }
            return nil
        }
        func lutronID(_ s: String) -> Int { Int(s) ?? abs(s.hashValue % 1_000_000) }
        func kindFor(type: String?) -> String {
            let t = (type ?? "").lowercased()
            if t.contains("shade") || t.contains("blind") || t.contains("drape") { return "shade" }
            if t.contains("switch") || t.contains("plug") || t.contains("relay") || t.contains("contact") { return "switch" }
            return "dimmer"
        }

        let byParent = Dictionary(grouping: tree.buttons.filter { $0.number != nil }, by: { $0.parent })
        var areas: [String: DeviceMap.Area] = [:]
        var nKeypads = 0, nButtons = 0, nOutputs = 0
        for d in tree.devices {
            let areaName = (d.area ?? "").isEmpty ? "unsorted" : d.area!.lowercased()
            var area = areas[areaName] ?? DeviceMap.Area(name: areaName, keypads: [], outputs: [])
            if let btns = byParent[d.id], !btns.isEmpty {
                var buttons: [DeviceMap.Button] = []
                for b in btns.sorted(by: { ($0.number ?? 0) < ($1.number ?? 0) }) {
                    let label = (b.name ?? "").isEmpty ? "Button \(b.number ?? 0)" : b.name!
                    let s = intentFor(area: areaName, label: label)
                    buttons.append(DeviceMap.Button(position: b.number, button: b.number, label: label,
                                                    kind: s?.kind ?? "output", subsystem: s?.subsystem,
                                                    intent: s?.intent, asBuilt: s?.asBuilt, remarks: s?.remarks))
                }
                area.keypads.append(DeviceMap.Keypad(name: d.name.isEmpty ? "keypad \(d.id)" : d.name,
                                                     lutronID: lutronID(d.id), buttons: buttons))
                nKeypads += 1; nButtons += buttons.count
            } else if d.zone != nil {
                area.outputs.append(DeviceMap.Output(name: d.name.isEmpty ? "load \(d.id)" : d.name,
                                                     lutronID: lutronID(d.id), kind: kindFor(type: d.type)))
                nOutputs += 1
            }
            areas[areaName] = area
        }
        let imported = areas.values.filter { !$0.keypads.isEmpty || !$0.outputs.isEmpty }.sorted { $0.name < $1.name }

        let hasCaptures = map.areas.contains { a in a.keypads.contains { k in k.buttons.contains { $0.button != nil } } || !a.outputs.isEmpty }
            || !(map.customMacros ?? []).isEmpty
        if !hasCaptures {
            map.areas = imported
        } else {
            for ia in imported {
                if let ai = map.areas.firstIndex(where: { $0.name == ia.name }) {
                    for kp in ia.keypads {
                        if let ki = map.areas[ai].keypads.firstIndex(where: { $0.lutronID == kp.lutronID }) {
                            map.areas[ai].keypads[ki].name = kp.name
                            for b in kp.buttons where !map.areas[ai].keypads[ki].buttons.contains(where: { $0.button == b.button }) {
                                map.areas[ai].keypads[ki].buttons.append(b)
                            }
                        } else { map.areas[ai].keypads.append(kp) }
                    }
                    for o in ia.outputs where !map.areas[ai].outputs.contains(where: { $0.lutronID == o.lutronID }) {
                        map.areas[ai].outputs.append(o)
                    }
                } else { map.areas.append(ia) }
            }
        }
        map.system = "LEAP"
        map.source = "LEAP device tree"
        save()
        return "Imported \(imported.count) rooms, \(nKeypads) keypads, \(nButtons) buttons, \(nOutputs) loads."
    }

    // MARK: - coverage

    struct Coverage {
        var captured: Int; var identified: Int; var pending: Int; var total: Int
        var fraction: Double { total == 0 ? 0 : Double(captured) / Double(total) }
    }

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

    /// Run a custom macro. `confirmed` must be true (observe-first).
    func runMacro(_ macro: CustomMacro, using client: LIPClient, confirmed: Bool) async {
        guard confirmed else { return }
        lastRunLog = ["Running \(macro.name)…"]
        for step in macro.steps {
            switch step.type {
            case .output, .press:
                if let cmd = CustomMacro.lipCommand(for: step) {
                    let ok = client.sendControl(cmd, confirmed: true)
                    lastRunLog.append((ok ? "sent " : "blocked ") + cmd)
                } else {
                    lastRunLog.append("skipped incomplete step")
                }
            case .delay:
                let ms = max(0, min(step.delayMs ?? 300, 60_000))
                lastRunLog.append("wait \(ms)ms")
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            case .savant:
                if let host = step.savantHost, !host.isEmpty,
                   let port = step.savantPort, (1...65535).contains(port),
                   let payload = step.savantPayload {
                    Self.sendRawTCP(host: host, port: UInt16(port), payload: payload)
                    lastRunLog.append("savant → \(host):\(port)")
                } else {
                    lastRunLog.append("skipped savant step (needs host, port 1–65535, payload)")
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000) // gentle pacing between steps
        }
        lastRunLog.append("Done.")
    }

    nonisolated static func sendRawTCP(host: String, port: UInt16, payload: String) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                let text = payload.replacingOccurrences(of: "\\r", with: "\r")
                                  .replacingOccurrences(of: "\\n", with: "\n")
                let data = text.data(using: .utf8) ?? Data()
                conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { conn.cancel() }
    }
}
