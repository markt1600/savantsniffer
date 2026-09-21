import SwiftUI

struct PortCheckView: View {
    @EnvironmentObject var portcheck: PortCheckModel
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Port check").font(.largeTitle.bold())
                Text("Opens a TCP connection to 23 / 8081 / 8083 to see which is answering. Sends nothing to the device beyond the handshake.")
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("processor IP", text: $portcheck.host).frame(width: 200)
                    Button(portcheck.checking ? "Checking…" : "Check ports") { portcheck.check() }
                        .disabled(portcheck.checking || portcheck.host.isEmpty)
                    if let p = store.map.processor, !p.isEmpty {
                        Button("Use \(p)") { portcheck.host = p }
                    }
                }

                ForEach(portcheck.results) { r in
                    HStack {
                        BoolDot(ok: r.open)
                        Text("\(r.port)").font(.body.monospaced()).frame(width: 50, alignment: .leading)
                        Text(r.open ? "OPEN" : "closed").foregroundStyle(r.open ? .green : .secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(PORT_LABELS[r.port] ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                if !portcheck.likelySystem.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Likely system: \(portcheck.likelySystem)").font(.headline)
                            Text(portcheck.reasoning).font(.callout).foregroundStyle(.secondary)
                            Button("Record this system") {
                                store.map.system = portcheck.likelySystem
                                if store.map.processor == nil { store.map.processor = portcheck.host }
                                store.save()
                            }
                        }.padding(6)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
