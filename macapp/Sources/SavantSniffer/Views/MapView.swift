import SwiftUI

struct MapView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Device map",
                           subtitle: "system \(store.map.system ?? "?") · processor \(store.map.processor ?? "?") · savant \(store.map.savantHost ?? "?")") {
                    Button("Merge starting layout") {
                        let r = store.mergeSeed()
                        note = "Added \(r.areas) rooms, \(r.keypads) keypads, \(r.buttons) buttons."
                    }
                    Button("Export report…") { exportReport() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(Theme.muted) }

                ForEach(store.map.areas) { area in
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(area.name.capitalized).font(.system(size: 14, weight: .bold))
                            ForEach(area.keypads) { kp in
                                Text(kp.name + (kp.lutronID != nil ? " · id \(kp.lutronID!)" : " · id ?"))
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).padding(.top, 4)
                                ForEach(kp.buttons) { b in
                                    HStack(spacing: 8) {
                                        StatusDot(status: b.status(keypadIdentified: kp.lutronID != nil))
                                        Text(b.label).font(.system(size: 12.5)).frame(width: 150, alignment: .leading)
                                        Chip.kind(b.kind)
                                        if let n = b.button { Text("btn \(n)").mono(11).foregroundStyle(Theme.muted) }
                                        if let e = b.effect, !e.isEmpty {
                                            Text(e.map { "\($0.id)→\(Int($0.level))" }.joined(separator: " ")).mono(11).foregroundStyle(Theme.muted)
                                        }
                                        if let z = b.audioZones, !z.isEmpty {
                                            Text("audio: " + z.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Theme.purple)
                                        }
                                        Spacer()
                                    }
                                }
                            }
                            if !area.outputs.isEmpty {
                                SectionLabel("Loads").padding(.top, 6)
                                ForEach(area.outputs) { o in
                                    HStack(spacing: 8) {
                                        LED(color: Theme.green)
                                        Text(o.name).font(.system(size: 12.5)).frame(width: 150, alignment: .leading)
                                        Text("id \(o.lutronID) · \(o.kind)").mono(11).foregroundStyle(Theme.muted)
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(26)
        }
    }

    private func exportReport() {
        let user = UserDefaults.standard.string(forKey: "lipUser") ?? "lutron"
        let creds = Exporter.Credentials(host: store.map.processor, user: user, password: Keychain.get(account: user),
                                         system: store.map.system, prompt: lip.prompt.isEmpty ? nil : lip.prompt,
                                         savantHost: store.map.savantHost)
        if let url = Exporter.save(map: store.map, creds: creds, coverage: store.overallCoverage()) {
            note = "Saved \(url.lastPathComponent) plus the JSON map beside it."
            store.map.lastExported = ISO8601DateFormatter().string(from: Date())
            store.save()
        }
    }
}
