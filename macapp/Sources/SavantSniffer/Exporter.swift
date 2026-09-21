import Foundation
import AppKit

/// Builds the integration report: everything discovered, with the exact commands
/// another app can send. Saved as Markdown, with the raw device map as JSON beside it.
enum Exporter {
    struct Credentials {
        var host: String?
        var user: String
        var password: String?
        var system: String?
        var prompt: String?
        var savantHost: String?
    }

    static func markdown(map: DeviceMap, creds: Credentials, coverage: DeviceStore.Coverage) -> String {
        var o: [String] = []
        let f = ISO8601DateFormatter()
        o.append("# Lutron / Savant integration report")
        o.append("")
        o.append("Generated \(f.string(from: Date())) by SavantSniffer. **Contains credentials — keep it private.**")
        o.append("")
        o.append("## Connection")
        o.append("")
        o.append("| Item | Value |")
        o.append("|---|---|")
        o.append("| Lutron processor | `\(creds.host ?? map.processor ?? "unknown")` |")
        o.append("| System | \(creds.system ?? map.system ?? "unknown")\(creds.prompt.map { " (prompt `\($0)`)" } ?? "") |")
        o.append("| Protocol | LIP over telnet, TCP port 23 |")
        o.append("| Login | user `\(creds.user)` / password `\(creds.password ?? "(not stored)")` |")
        o.append("| Access verified | \((map.accessOK ?? false) ? "yes" : "no") |")
        o.append("| Savant host | `\(creds.savantHost ?? map.savantHost ?? "unknown")` |")
        o.append("")
        o.append("## Protocol cheat sheet")
        o.append("")
        if (map.system ?? "").uppercased().contains("LEAP") {
            o.append("This processor speaks LEAP (TLS on 8081, pair once; certificates in ~/Library/Application Support/SavantSniffer/leap).")
            o.append("Ids below are LEAP device ids. The bundled leap_bridge.py maps them: `SET <device> <level> [fade]`, `PRESS <device> <button>`.")
            o.append("The telnet (LIP) commands are listed for reference; they apply if LIP is enabled on the processor.")
            o.append("")
        }
        o.append("```")
        o.append("open TCP \(creds.host ?? map.processor ?? "<processor>"):23")
        o.append("<- login:      -> send \"\(creds.user)\\r\\n\"")
        o.append("<- password:   -> send \"\(creds.password ?? "<password>")\\r\\n\"")
        o.append("<- \(creds.prompt ?? "QNET>")        (ready)")
        o.append("#MONITORING,3,1          enable keypad (~DEVICE) events")
        o.append("#MONITORING,5,1          enable load (~OUTPUT) events")
        o.append("?OUTPUT,<id>,1           query a load's level  -> ~OUTPUT,<id>,1,<level>")
        o.append("#OUTPUT,<id>,1,<level>   set a load 0–100")
        o.append("#OUTPUT,<id>,1,<level>,<fade-seconds>   set with a fade (e.g. 20,2)")
        o.append("#OUTPUT,<id>,2 / 3 / 4   raise / lower / stop (dim up-down buttons)")
        o.append("#DEVICE,<keypad>,<btn>,3 press a keypad button (4 = release)")
        o.append("```")
        o.append("")
        o.append("## Coverage")
        o.append("")
        o.append("\(coverage.captured) of \(coverage.total) buttons fully captured, \(coverage.identified) partial, \(coverage.pending) pending.")
        o.append("")

        for area in map.areas {
            o.append("## \(area.name.capitalized)")
            o.append("")
            for kp in area.keypads {
                let kid = kp.lutronID.map { String($0) } ?? "?"
                o.append("### Keypad: \(kp.name) (Lutron id \(kid))")
                o.append("")
                o.append("| Button | Kind | # | Press command | Status | Effect / notes |")
                o.append("|---|---|---|---|---|---|")
                for b in kp.buttons {
                    let st = b.status(keypadIdentified: kp.lutronID != nil).rawValue
                    let num = b.button.map { String($0) } ?? "?"
                    let cmd = (kp.lutronID != nil && b.button != nil) ? "`#DEVICE,\(kid),\(num),3`" : "—"
                    var notes: [String] = []
                    if let e = b.effect, !e.isEmpty {
                        notes.append(e.map { "\($0.id)→\(fmt($0.level))" }.joined(separator: ", "))
                    }
                    if let z = b.audioZones, !z.isEmpty {
                        notes.append("audio zones: " + z.joined(separator: ", ") + (b.audioSource.map { " from \($0)" } ?? ""))
                    }
                    if b.kind == "integration" {
                        notes.append((b.savantCaptured ?? false) ? "Savant: \(b.savantNote ?? "captured")" : "Savant side not captured")
                    }
                    if let i = b.intent, !i.isEmpty { notes.append("intent: \(i)") }
                    o.append("| \(b.label) | \(b.kind) | \(num) | \(cmd) | \(st) | \(notes.joined(separator: "; ")) |")
                }
                o.append("")
            }
            if !area.outputs.isEmpty {
                o.append("### Loads")
                o.append("")
                o.append("| Load | Lutron id | Kind | Set | Query |")
                o.append("|---|---|---|---|---|")
                for out in area.outputs {
                    o.append("| \(out.name) | \(out.lutronID) | \(out.kind) | `#OUTPUT,\(out.lutronID),1,<0-100>` | `?OUTPUT,\(out.lutronID),1` |")
                }
                o.append("")
            }
        }

        let macros = map.customMacros ?? []
        if !macros.isEmpty {
            o.append("## Custom scenes")
            o.append("")
            for m in macros {
                o.append("### \(m.name)")
                o.append("")
                o.append("```")
                for s in m.steps { o.append(CustomMacro.previewLine(for: s)) }
                o.append("```")
                o.append("")
            }
        }

        let pendingSavant = map.areas.flatMap { a in
            a.keypads.flatMap { k in k.buttons.filter { $0.kind == "integration" && !($0.savantCaptured ?? false) }
                .map { "\(a.name) · \(k.name) · \($0.label)" } }
        }
        if !pendingSavant.isEmpty {
            o.append("## Integration buttons still needing Savant-side capture")
            o.append("")
            for p in pendingSavant { o.append("- \(p)") }
            o.append("")
        }
        return o.joined(separator: "\n")
    }

    private static func fmt(_ d: Double) -> String { String(format: "%g", d) }

    /// One-call export used by every screen: builds credentials from the Keychain,
    /// shows the save panel, writes both files, records the export date.
    @MainActor
    static func exportViaPanel(store: DeviceStore, lip: LIPClient) -> String {
        let user = UserDefaults.standard.string(forKey: "lipUser") ?? "lutron"
        let creds = Credentials(host: store.map.processor, user: user, password: Keychain.get(account: user),
                                system: store.map.system, prompt: lip.prompt.isEmpty ? nil : lip.prompt,
                                savantHost: store.map.savantHost)
        guard let url = save(map: store.map, creds: creds, coverage: store.overallCoverage()) else { return "" }
        store.map.lastExported = ISO8601DateFormatter().string(from: Date())
        store.save()
        return "Saved \(url.lastPathComponent) plus the JSON map beside it."
    }

    /// Ask where to save, then write the Markdown report and the JSON map beside it.
    @MainActor
    static func save(map: DeviceMap, creds: Credentials, coverage: DeviceStore.Coverage) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SavantSniffer-report.md"
        panel.canCreateDirectories = true
        panel.title = "Export integration report"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let md = markdown(map: map, creds: creds, coverage: coverage)
        try? md.write(to: url, atomically: true, encoding: .utf8)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(map) {
            try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }
        return url
    }
}
