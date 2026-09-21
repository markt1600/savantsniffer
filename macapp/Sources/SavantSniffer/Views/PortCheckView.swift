import SwiftUI

struct PortCheckView: View {
    @EnvironmentObject var portcheck: PortCheckModel
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Port check",
                           subtitle: "Opens a TCP connection to 23 / 8081 / 8083 to see which answers. Sends nothing beyond the handshake.") {
                    EmptyView()
                }
                Card {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Processor IP").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                            TextField("192.168.1.50", text: $portcheck.host).textFieldStyle(.roundedBorder).mono(13).frame(width: 180)
                        }
                        if let p = store.map.processor, !p.isEmpty, p != portcheck.host {
                            Button("Use \(p)") { portcheck.host = p }
                        }
                        Button(portcheck.checking ? "Checking…" : "Check ports") { portcheck.check() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(portcheck.checking || portcheck.host.isEmpty)
                    }
                }
                if !portcheck.results.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(portcheck.results) { r in
                                HStack(spacing: 12) {
                                    BoolDot(ok: r.open)
                                    Text("\(r.port)").mono(13).frame(width: 50, alignment: .leading)
                                    Text(r.open ? "OPEN" : "closed").font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(r.open ? Theme.greenInk : Theme.muted).frame(width: 60, alignment: .leading)
                                    Text(PORT_LABELS[r.port] ?? "").font(.caption).foregroundStyle(Theme.muted)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                if !portcheck.likelySystem.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Likely system: \(portcheck.likelySystem)").font(.system(size: 15, weight: .bold))
                            Text(portcheck.reasoning).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            Button("Record this") {
                                store.map.system = portcheck.likelySystem
                                if (store.map.processor ?? "").isEmpty { store.map.processor = portcheck.host }
                                store.save()
                            }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                        }
                    }
                }
            }
            .padding(26)
        }
    }
}
