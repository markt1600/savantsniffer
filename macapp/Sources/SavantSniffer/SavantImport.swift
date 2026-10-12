import Foundation

/// Reads a copy of the Savant host's RacePointMedia folder and turns it into the
/// device map: every room, Lutron keypad button (with its LEAP href), load, shade
/// group, the Savant-side action behind the music/volume/broadcast buttons, the
/// audio-zone wiring, and the AV devices with their addresses.
///
/// Read-only. Nothing touches the network or the Savant host.
enum SavantImport {

    struct Result {
        var areas: [DeviceMap.Area]
        var info: DeviceMap.SavantInfo
        var summary: String
    }

    enum ImportError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): return "Could not find \(what) under the chosen folder. Pick the folder that contains userConfig.rpmConfig (a copy of the Mac mini's RacePointMedia folder is ideal)."
            }
        }
    }

    // MARK: - locate files

    struct Files {
        var lite: URL?
        var userConnection: URL?
        var zoneConfig: URL?
        var loadgroups: URL?
        var sysInfo: URL?
        var workflows: [URL] = []
        var olaConfig: [URL] = []
        var networkDevice: [URL] = []
        var controllers: [URL] = []
    }

    static func locate(_ root: URL) -> Files {
        var f = Files()
        let skip: Set<String> = ["www", "Plugins", "tftpboot", "UpgradeInfo", "Music", "ArtworkCache", "swaggerui", "images", "DIS", "componentProfiles"]
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return f }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        for case let url as URL in en {
            let depth = url.standardizedFileURL.pathComponents.count - rootDepth
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if skip.contains(url.lastPathComponent) || depth > 8 { en.skipDescendants() }
                continue
            }
            let name = url.lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            let inDeployed = url.path.contains("userConfig.rpmConfig")
            func take(_ slot: inout URL?) { if slot == nil || (inDeployed && !(slot!.path.contains("userConfig.rpmConfig"))) { slot = url } }
            switch name {
            case "LiteInterfaceConfiguration.plist": take(&f.lite)
            case "userConnection.xml": take(&f.userConnection)
            case "zoneConfig.xml": take(&f.zoneConfig)
            case "loadgroups.out": take(&f.loadgroups)
            case "rpmSystemInfo.plist": take(&f.sysInfo)
            case "document.wflow": f.workflows.append(url)
            default:
                if parent == "OLAConfig" { f.olaConfig.append(url) }
                else if parent == "NetworkDevice" { f.networkDevice.append(url) }
                else if parent == "controllers" { f.controllers.append(url) }
            }
        }
        let deployed = f.workflows.filter { $0.path.contains("userConfig.rpmConfig") }
        if !deployed.isEmpty { f.workflows = deployed }
        return f
    }

    // MARK: - small readers

    static func plist(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    static func jsonOrPlist(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let j = try? JSONSerialization.jsonObject(with: data) { return j }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    static func hrefNumber(_ href: String?) -> Int? {
        guard let h = href, let r = h.range(of: #"(\d+)$"#, options: .regularExpression) else { return nil }
        return Int(h[r])
    }
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    /// Savant lighting UIDs are the device MAC plus a product id: 985DAD7CC081 0042.
    static func macFromUID(_ uid: String) -> String {
        guard uid.count >= 12, uid.range(of: #"^[0-9A-Fa-f]+$"#, options: .regularExpression) != nil else { return "" }
        let h = Array(uid.prefix(12).lowercased())
        return stride(from: 0, to: 12, by: 2).map { String(h[$0..<$0 + 2]) }.joined(separator: ":")
    }

    // MARK: - intermediate records

    struct RawLoad { var name: String; var room: String; var href: String; var subtype: String; var loadID: String }
    struct RawButton { var label: String; var room: String; var href: String; var led: String; var uid: String; var offset: String
        var workflows: [String] = []; var actions: [String] = [] }
    struct RawWorkflow { var room: String; var service: String; var name: String; var actions: [String] }

    // MARK: - parsers

    static func parseLighting(_ url: URL) -> (loads: [RawLoad], shades: [RawLoad], buttons: [RawButton], areas: [String: [String]], uid: String, controller: String)? {
        guard let d = plist(url) as? [String: Any], let ctrls = d["Controllers"] as? [String: Any] else { return nil }
        var loads: [RawLoad] = [], shades: [RawLoad] = [], buttons: [RawButton] = []
        var areas: [String: [String]] = [:]; var uid = ""; var cname = ""
        for (name, c) in ctrls {
            cname = name
            guard let cd = c as? [String: Any] else { continue }
            for kp in (cd["Keypads"] as? [[String: Any]]) ?? [] {
                if let a = kp["Areas"] as? [String: [String]] { areas.merge(a) { $1 } }
                uid = (kp["UID"] as? String) ?? uid
                for l in (kp["Loads"] as? [[String: Any]]) ?? [] {
                    loads.append(RawLoad(name: (l["LoadName"] as? String) ?? "", room: (l["LoadZone"] as? String) ?? "",
                                         href: (l["Href"] as? String) ?? "", subtype: (l["LoadSubType"] as? String) ?? "",
                                         loadID: (l["LoadID"] as? String) ?? ""))
                }
                for s in (kp["Shades"] as? [[String: Any]]) ?? [] {
                    shades.append(RawLoad(name: (s["LoadName"] as? String) ?? "", room: (s["LoadZone"] as? String) ?? "",
                                          href: (s["Href"] as? String) ?? "", subtype: "SHADE_GROUP", loadID: (s["LoadID"] as? String) ?? ""))
                }
                for b in (kp["Scenes"] as? [[String: Any]]) ?? [] {   // Savant calls Lutron buttons "Scenes"
                    buttons.append(RawButton(label: clean((b["DeviceLabel"] as? String) ?? ""), room: (b["SavantZone"] as? String) ?? "",
                                             href: (b["Href"] as? String) ?? "", led: (b["LEDref"] as? String) ?? "",
                                             uid: (b["DeviceUID"] as? String) ?? "", offset: "\(b["Offset"] ?? "")"))
                }
            }
        }
        return (loads, shades, buttons, areas, uid, cname)
    }

    static func parseWorkflows(_ urls: [URL]) -> [RawWorkflow] {
        var out: [RawWorkflow] = []
        for u in urls.sorted(by: { $0.path < $1.path }) {
            let comps = u.pathComponents
            guard comps.count >= 5 else { continue }
            let room = comps[comps.count - 5], service = comps[comps.count - 4]
            let wf = comps[comps.count - 3].replacingOccurrences(of: ".workflow", with: "")
            guard let doc = plist(u) as? [String: Any] else { continue }
            var texts: [String] = []
            for a in (doc["actions"] as? [[String: Any]]) ?? [] {
                let act = (a["action"] as? [String: Any]) ?? a
                let prm = (act["ActionParameters"] as? [String: Any]) ?? [:]
                let cls = (prm["RPMClassName"] as? String) ?? ""
                let name = (act["ActionName"] as? String) ?? (act["AMActionName"] as? String) ?? ""
                if cls == "avAction" {
                    let comp = (prm["componentID"] as? String) ?? "", logical = (prm["logicalComponentName"] as? String) ?? ""
                    let cmd = (prm["actionName"] as? String) ?? ""
                    var argtxt = ""
                    for arg in (prm["arguments"] as? [[String: Any]]) ?? [] {
                        let v = "\(arg["argValue"] ?? "")"
                        if (arg["argName"] as? String) == "GUID", v.hasPrefix("connect:preset:") { argtxt = " (Spotify preset)" }
                        else if !v.isEmpty, ["Address1", "ThermostatAddress"].contains((arg["argName"] as? String) ?? "") { argtxt += " \(arg["argName"] ?? "")=\(v)" }
                    }
                    texts.append("\(comp) / \(logical): \(cmd)\(argtxt)")
                } else if cls == "svcCallServiceAction" {
                    var scene = ""
                    for arg in (prm["arguments"] as? [[String: Any]]) ?? [] where (arg["name"] as? String) == "SceneName" { scene = (arg["value"] as? String) ?? "" }
                    let ev = (prm["selectedEvent"] as? String) ?? "", zone = (prm["selectedZone"] as? String) ?? ""
                    texts.append(scene.isEmpty ? "\(ev) (\(prm["selectedService"] ?? ""))" : "\(ev) '\(scene)' in \(zone)")
                } else if cls == "rpmStateSetAction" {
                    texts.append("set state \(prm["stateName"] ?? "") = \(prm["stateValue"] ?? "")")
                } else if name == "Run Shell Script", let cmd = (prm["COMMAND_STRING"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                    texts.append("shell: " + String(cmd.prefix(160)))
                }
            }
            out.append(RawWorkflow(room: room, service: String(service.split(separator: "-").last ?? ""), name: wf, actions: texts))
        }
        return out
    }

    static func parseUserConnection(_ url: URL) -> (devices: [DeviceMap.SavantInfo.AVDevice], wiring: [String: String]) {
        guard let doc = try? XMLDocument(contentsOf: url, options: []) else { return ([], [:]) }
        var devices: [DeviceMap.SavantInfo.AVDevice] = []; var wiring: [String: String] = [:]
        var seen = Set<String>()
        for comp in (try? doc.nodes(forXPath: "//component")) as? [XMLElement] ?? [] {
            let name = comp.attribute(forName: "user_defined_name")?.stringValue ?? ""
            for ipc in (try? comp.nodes(forXPath: ".//ip_control")) as? [XMLElement] ?? [] {
                var addr = ipc.attribute(forName: "address")?.stringValue ?? ""
                var creds = ""
                if let at = addr.range(of: "@", options: .backwards) { creds = String(addr[..<at.lowerBound]); addr = String(addr[at.upperBound...]) }
                let port = ipc.attribute(forName: "port")?.stringValue ?? ""
                let key = name + "|" + addr + "|" + port
                if seen.insert(key).inserted {
                    devices.append(.init(name: name, room: "", ip: addr, port: port, protocolHint: protocolHint(name: name, port: port), credentials: creds))
                }
            }
            for irc in (try? comp.nodes(forXPath: ".//ir_control")) as? [XMLElement] ?? [] {
                let mp = ((try? irc.nodes(forXPath: "master_controller_port")) as? [XMLElement])?.first
                let hint = mp.map { "IR via \($0.attribute(forName: "master_name")?.stringValue ?? "") \($0.attribute(forName: "name")?.stringValue ?? "")" } ?? "IR"
                let key = name + "|IR"
                if seen.insert(key).inserted { devices.append(.init(name: name, room: "", ip: "", port: "IR", protocolHint: hint, credentials: "")) }
            }
            for outp in (try? comp.nodes(forXPath: "output[audio_media]")) as? [XMLElement] ?? [] {
                let oname = outp.attribute(forName: "name_on_component")?.stringValue ?? ""
                for peer in (try? outp.nodes(forXPath: ".//peer_io")) as? [XMLElement] ?? [] {
                    let target = peer.attribute(forName: "user_defined_name")?.stringValue ?? ""
                    if target.contains("Speaker") || target.contains("Beolab") { wiring["\(name) :: \(oname)"] = target }
                }
            }
        }
        return (devices, wiring)
    }

    static func protocolHint(name: String, port: String) -> String {
        switch port {
        case "23": return "telnet (plain text; capturable)"
        case "10102": return "CoolAutomation CoolLink TCP (plain text)"
        case "80": return "HTTP (Bond / Hue / camera APIs)"
        case "443": return "HTTPS"
        case "31415": return "Big Ass Fans SenseME"
        case "20554": return "JVC projector IP control"
        case "0": return name.lowercased().contains("atv") ? "Apple TV (HomeKit / Companion)" : ""
        default: return ""
        }
    }

    static func parseZoneConfig(_ url: URL) -> [String: String] {
        guard let doc = try? XMLDocument(contentsOf: url, options: []) else { return [:] }
        var rooms: [String: String] = [:]
        for zone in (try? doc.nodes(forXPath: "//zone")) as? [XMLElement] ?? [] {
            let zname = zone.attribute(forName: "name")?.stringValue ?? ""
            for c in (try? zone.nodes(forXPath: ".//component")) as? [XMLElement] ?? [] {
                if let n = c.attribute(forName: "user_defined_name")?.stringValue, rooms[n] == nil { rooms[n] = zname }
            }
        }
        return rooms
    }

    static func parseLoadLevels(_ url: URL) -> [String: Int] {
        guard let txt = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: Int] = [:]
        let re = try! NSRegularExpression(pattern: #"(?m)^Scene (.+?) Scene: Offset\(\d+\).*?\n\tPreset (\d+)%, Current (\d+)%\n\t([0-9A-F]+),"#)
        for m in re.matches(in: txt, range: NSRange(txt.startIndex..., in: txt)) {
            if let nr = Range(m.range(at: 1), in: txt), let cr = Range(m.range(at: 3), in: txt), let v = Int(txt[cr]) { out[String(txt[nr])] = v }
        }
        return out
    }

    static func parseOLA(_ urls: [URL]) -> [String: String] {
        var out: [String: String] = [:]
        for u in urls {
            guard let d = jsonOrPlist(u) as? [String: Any] else { continue }
            for e in d.values {
                guard let ed = e as? [String: Any], let href = ed["Href"] as? String else { continue }
                let zm = (ed["ZoneMapping"] as? [String: Any]) ?? [:]
                out[href] = ((zm["LutronAreas"] as? [String]) ?? []).joined(separator: ", ")
            }
        }
        return out
    }

    // MARK: - inference

    static func classify(_ label: String) -> (kind: String, intent: String) {
        let l = label.lowercased()
        let last = l.split(separator: " ").last.map(String.init) ?? l
        if ["music", "vol up", "vol down", "broadcast", "movie", "spotify"].contains(where: { l.contains($0) }) { return ("integration", "Savant: audio / media") }
        if last == "ac" || last == "dehumidify" { return ("hvac", "Savant: HVAC") }
        if l.contains("curtain") || l.contains("shade") || l == "open" || l == "close" { return ("shade", "Lutron shade group") }
        if l.contains("fan") { return ("fan", "Lutron relay (fan)") }
        if ["off", "ambient", "relaxed", "focused", "evening", "morning", "night light", "home light", "color"].contains(where: { l.contains($0) }) { return ("macro", "Lutron scene (several loads)") }
        return ("output", "Lutron load")
    }

    static func workflowKey(_ name: String) -> String {
        var n = name.replacingOccurrences(of: #"\s*\(.*?\)\s*$"#, with: "", options: .regularExpression).lowercased().trimmingCharacters(in: .whitespaces)
        for suf in [" on scene", " off scene", " scene", " on", " enable", " disable"] where n.hasSuffix(suf) { n = String(n.dropLast(suf.count)).trimmingCharacters(in: .whitespaces); break }
        return n
    }

    static func link(_ buttons: inout [RawButton], _ workflows: [RawWorkflow]) {
        let usable = workflows.filter { !$0.actions.isEmpty && $0.name != "RunCLIProgram" && $0.name != "test" }
        let byRoom = Dictionary(grouping: usable, by: { $0.room })
        for i in buttons.indices {
            let bk = buttons[i].label.lowercased().trimmingCharacters(in: .whitespaces)
            var hits: [RawWorkflow] = []
            for wf in byRoom[buttons[i].room] ?? [] {
                let wk = workflowKey(wf.name)
                if wk == bk || (bk == "music" && (wk == "music" || wk == "music on")) || (bk == "broadcast" && wk.hasPrefix("broadcast"))
                    || (bk == "movie" && wk.hasPrefix("movie")) { hits.append(wf) }
            }
            if !hits.isEmpty {
                buttons[i].workflows = hits.map { "\($0.name) [\($0.service)]" }
                var seen = Set<String>()
                buttons[i].actions = hits.flatMap { $0.actions }.filter { seen.insert($0).inserted }
            }
        }
    }

    static func audioZones(_ wiring: [String: String], rooms: [String: String]) -> [String: String] {
        var zones: [String: String] = [:]
        for (k, speakers) in wiring {
            let parts = k.components(separatedBy: " :: ")
            guard parts.count == 2 else { continue }
            let room = rooms[speakers] ?? speakers.replacingOccurrences(of: #"\s*(Speakers?|Beolab ?50.*)$"#, with: "", options: .regularExpression)
            if let r = parts[1].range(of: #"(\d+)\s*$"#, options: .regularExpression) {
                zones["\(parts[0]):Audio Zone \(parts[1][r].trimmingCharacters(in: .whitespaces))"] = room
            } else {
                zones["\(parts[0]):\(parts[1])"] = room
            }
        }
        return zones
    }

    static func zonesFor(actions: [String], zones: [String: String]) -> [String] {
        var out: [String] = []
        for a in actions {
            for (key, room) in zones {
                let p = key.components(separatedBy: ":")
                guard p.count >= 2 else { continue }
                if a.hasPrefix(p[0] + " / " + p[1...].joined(separator: ":") + ":"), !out.contains(room), !room.isEmpty { out.append(room) }
            }
        }
        return out
    }

    // MARK: - main entry

    static func read(folder: URL, seedIntent: (String, String) -> DeviceMap.Button?) throws -> Result {
        let files = locate(folder)
        guard let liteURL = files.lite, let lighting = parseLighting(liteURL) else { throw ImportError.missing("LiteInterfaceConfiguration.plist") }
        var info = DeviceMap.SavantInfo()
        info.importedAt = ISO8601DateFormatter().string(from: Date())
        info.sourceFolder = folder.path
        info.systemName = lighting.controller
        if let s = files.sysInfo, let d = plist(s) as? [String: Any], let n = d["RPMSystemName"] as? String, !n.isEmpty { info.systemName = n }
        info.bridgeMAC = macFromUID(lighting.uid)
        info.lutronAreas = lighting.areas
        for u in files.networkDevice {
            if let d = jsonOrPlist(u) as? [String: Any], let ip = d["ip"] as? String, !ip.isEmpty { info.bridgeIP = ip; break }
        }
        for u in files.controllers {
            if let d = jsonOrPlist(u) as? [String: Any], let mac = d["controllerMacAddr"] as? String, !mac.isEmpty { info.processorMAC = mac.lowercased(); break }
        }
        let ola = parseOLA(files.olaConfig)
        let workflows = parseWorkflows(files.workflows)
        let (devices, wiring) = files.userConnection.map(parseUserConnection) ?? ([], [:])
        let rooms = files.zoneConfig.map(parseZoneConfig) ?? [:]
        info.devices = devices.map { var d = $0; d.room = rooms[d.name] ?? ""; return d }.sorted { ($0.room, $0.name) < ($1.room, $1.name) }
        info.audioZones = audioZones(wiring, rooms: rooms)
        info.workflows = workflows.filter { !$0.actions.isEmpty && $0.name != "RunCLIProgram" && $0.name != "test" }
            .map { .init(room: $0.room, service: $0.service, name: $0.name, actions: $0.actions) }
        let levels = files.loadgroups.map(parseLoadLevels) ?? [:]
        var buttons = lighting.buttons
        link(&buttons, workflows)

        // ---- device map
        var areas: [String: DeviceMap.Area] = [:]
        func area(_ name: String) -> DeviceMap.Area {
            let key = name.isEmpty ? "unsorted" : name.lowercased()
            return areas[key] ?? DeviceMap.Area(name: key, keypads: [], outputs: [])
        }
        func put(_ a: DeviceMap.Area) { areas[a.name] = a }

        for l in lighting.loads {
            guard let zid = hrefNumber(l.href) else { continue }
            var a = area(l.room)
            a.outputs.append(DeviceMap.Output(name: l.name, lutronID: zid, kind: l.subtype == "RELAY" ? "switch" : "dimmer",
                                              href: l.href, lutronArea: ola[l.href], levelAtImport: levels[l.name]))
            put(a)
        }
        for s in lighting.shades {
            guard let zid = hrefNumber(s.href) else { continue }
            var a = area(s.room)
            a.outputs.append(DeviceMap.Output(name: s.name, lutronID: zid, kind: "shade", href: s.href, lutronArea: ola[s.href], levelAtImport: nil))
            put(a)
        }
        // Savant does not record which physical keypad a button sits on, only its room:
        // one keypad entry per room, regrouped by real keypad once the LEAP tree is imported.
        for b in buttons {
            guard let bid = hrefNumber(b.href) else { continue }
            var a = area(b.room)
            let kpName = "\(a.name) keypads"
            var kp = a.keypads.first(where: { $0.name == kpName }) ?? DeviceMap.Keypad(name: kpName, lutronID: nil, buttons: [])
            let (kind, intent) = classify(b.label)
            let seed = seedIntent(a.name, b.label)
            var btn = DeviceMap.Button(position: Int(b.offset), button: nil, label: b.label, kind: seed?.kind ?? kind,
                                       subsystem: seed?.subsystem, intent: seed?.intent ?? intent, asBuilt: seed?.asBuilt, remarks: seed?.remarks)
            btn.href = b.href
            btn.ledHref = b.led.isEmpty ? nil : b.led
            if !b.workflows.isEmpty {
                btn.savantWorkflows = b.workflows
                btn.savantActions = b.actions
                let z = zonesFor(actions: b.actions, zones: info.audioZones ?? [:])
                if !z.isEmpty { btn.audioZones = z }
                if b.actions.contains(where: { $0.contains("Spotify preset") }) { btn.audioSource = "Savant Music (Spotify preset on the media server)" }
                btn.savantCaptured = true
                btn.savantNote = "from the Savant configuration: " + b.workflows.joined(separator: ", ") + " (linked by name; confirm live)"
                if btn.kind == "output" || btn.kind == "hvac" { btn.kind = "integration" }
            }
            a.keypads.removeAll { $0.name == kpName }
            kp.buttons.append(btn)
            a.keypads.append(kp)
            put(a)
        }
        let list = areas.values.sorted { $0.name < $1.name }
        info.counts = ["rooms": list.count, "buttons": buttons.count, "loads": lighting.loads.count,
                       "shades": lighting.shades.count, "workflows": info.workflows?.count ?? 0, "devices": devices.count]
        var notes: [String] = []
        if (info.processorMAC ?? "").isEmpty { notes.append("statusfiles/controllers was not in the copy: processor MAC unknown") }
        if (info.bridgeIP ?? "").isEmpty { notes.append("lighting/shm/sdo/NetworkDevice was not in the copy: bridge IP unknown") }
        if files.workflows.isEmpty { notes.append("no workflows folder: Savant-side button actions unknown") }
        info.notes = notes
        let summary = "Imported \(list.count) rooms, \(buttons.count) keypad buttons, \(lighting.loads.count) loads, \(lighting.shades.count) shade groups, \(info.workflows?.count ?? 0) workflows, \(devices.count) AV devices."
        return Result(areas: list, info: info, summary: summary)
    }
}

// MARK: - applying the import to the store

extension DeviceStore {
    /// Fill the map from a copy of the Savant host's RacePointMedia folder.
    /// Replaces the scaffold when nothing has been captured yet; otherwise merges
    /// by LEAP href and keeps every captured value.
    @discardableResult
    func importSavant(folder: URL) -> String {
        let seed = DeviceStore.loadSeed()
        var seedByKey: [String: DeviceMap.Button] = [:]
        var seedByLabel: [String: [DeviceMap.Button]] = [:]
        for a in seed?.areas ?? [] { for k in a.keypads { for b in k.buttons {
            seedByKey[a.name.lowercased() + "|" + b.label.lowercased()] = b
            seedByLabel[b.label.lowercased(), default: []].append(b)
        } } }
        func seedIntent(area: String, label: String) -> DeviceMap.Button? {
            if let b = seedByKey[area.lowercased() + "|" + label.lowercased()] { return b }
            if let l = seedByLabel[label.lowercased()], l.count == 1 { return l[0] }
            return nil
        }
        let result: SavantImport.Result
        do { result = try SavantImport.read(folder: folder, seedIntent: seedIntent) }
        catch { return error.localizedDescription }

        let hasCaptures = map.areas.contains { a in a.keypads.contains { k in k.buttons.contains { $0.button != nil || ($0.effect?.isEmpty == false) || ($0.seenLive ?? false) } } }
            || !(map.customMacros ?? []).isEmpty
        if !hasCaptures {
            map.areas = result.areas
        } else {
            for ia in result.areas {
                guard let ai = map.areas.firstIndex(where: { $0.name == ia.name }) else { map.areas.append(ia); continue }
                for kp in ia.keypads {
                    if let ki = map.areas[ai].keypads.firstIndex(where: { $0.name == kp.name }) {
                        for b in kp.buttons where !map.areas[ai].keypads[ki].buttons.contains(where: { $0.href == b.href || ($0.label == b.label && $0.button != nil) }) {
                            map.areas[ai].keypads[ki].buttons.append(b)
                        }
                    } else { map.areas[ai].keypads.append(kp) }
                }
                for o in ia.outputs where !map.areas[ai].outputs.contains(where: { $0.lutronID == o.lutronID }) {
                    map.areas[ai].outputs.append(o)
                }
            }
        }
        map.savant = result.info
        map.system = "LEAP"
        map.source = "Savant configuration import"
        save()
        return result.summary
    }

    /// After a LEAP device-tree import: regroup Savant-imported buttons under their
    /// real keypads (button hrefs match the tree's button ids) and carry labels over.
    func regroupByLEAPTree(_ tree: LEAPTree) {
        var byButtonID: [Int: (parent: String, number: Int?, name: String?)] = [:]
        for b in tree.buttons { if let i = Int(b.id) { byButtonID[i] = (b.parent, b.number, b.name) } }
        guard !byButtonID.isEmpty else { return }
        let deviceName = Dictionary(tree.devices.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for ai in map.areas.indices {
            var moved: [DeviceMap.Button] = []
            for ki in map.areas[ai].keypads.indices where map.areas[ai].keypads[ki].name.hasSuffix(" keypads") {
                let keep = map.areas[ai].keypads[ki].buttons.filter { b in
                    guard let id = SavantImport.hrefNumber(b.href), byButtonID[id] != nil else { return true }
                    moved.append(b); return false
                }
                map.areas[ai].keypads[ki].buttons = keep
            }
            map.areas[ai].keypads.removeAll { $0.buttons.isEmpty && $0.name.hasSuffix(" keypads") }
            for var b in moved {
                guard let id = SavantImport.hrefNumber(b.href), let t = byButtonID[id] else { continue }
                let kpName = (deviceName[t.parent] ?? "").isEmpty ? "keypad \(t.parent)" : deviceName[t.parent]!
                let kpID = Int(t.parent) ?? abs(t.parent.hashValue % 1_000_000)
                b.button = t.number ?? b.button
                b.position = t.number ?? b.position
                if let ki = map.areas[ai].keypads.firstIndex(where: { $0.lutronID == kpID }) {
                    if let bi = map.areas[ai].keypads[ki].buttons.firstIndex(where: { $0.button == b.button }) {
                        var existing = map.areas[ai].keypads[ki].buttons[bi]
                        existing.href = b.href; existing.ledHref = b.ledHref
                        if existing.savantActions == nil { existing.savantActions = b.savantActions; existing.savantWorkflows = b.savantWorkflows }
                        if existing.audioZones == nil { existing.audioZones = b.audioZones; existing.audioSource = b.audioSource }
                        if existing.savantCaptured != true { existing.savantCaptured = b.savantCaptured; existing.savantNote = b.savantNote }
                        if existing.intent == nil { existing.intent = b.intent }
                        map.areas[ai].keypads[ki].buttons[bi] = existing
                    } else { map.areas[ai].keypads[ki].buttons.append(b) }
                } else {
                    map.areas[ai].keypads.append(DeviceMap.Keypad(name: kpName, lutronID: kpID, buttons: [b]))
                }
            }
            for ki in map.areas[ai].keypads.indices { map.areas[ai].keypads[ki].buttons.sort { ($0.button ?? 0) < ($1.button ?? 0) } }
        }
        save()
    }
}
