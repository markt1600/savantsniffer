import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var discovery: DiscoveryModel
    @EnvironmentObject var store: DeviceStore
    @State private var showCommand = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Discover hosts").font(.largeTitle.bold())
                Text("Scans only your local subnet. The exact command is shown first — you approve it before it runs.")
                    .foregroundStyle(.secondary)

                GroupBox("Tools on this Mac") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(discovery.tools, id: \.name) { t in
                            HStack {
                                BoolDot(ok: t.present)
                                Text(t.name)
                                if !t.present { Text("install: \(t.hint)").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                            }
                        }
                    }.padding(6)
                }

                HStack {
                    TextField("subnet", text: $discovery.subnet)
                        .frame(width: 200)
                        .onChange(of: discovery.subnet) { _ in discovery.buildCommand() }
                    Button("Show scan command") { discovery.buildCommand(); showCommand = true }
                }

                if showCommand {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(discovery.scanCommand).font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Text(discovery.note).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(discovery.scanning ? "Scanning…" : "I approve — run this scan") {
                                    discovery.runScan()
                                }.disabled(discovery.scanning)
                                if discovery.needsSudo {
                                    Text("Needs admin rights; you may be prompted, or run it in Terminal.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(6)
                    }
                }

                if let err = discovery.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                if !discovery.hosts.isEmpty {
                    Text("Results").font(.title2.bold())
                    ForEach(discovery.hosts) { h in
                        HStack {
                            Circle().fill(color(h.classification)).frame(width: 10, height: 10)
                            Text(h.ip).font(.body.monospaced()).frame(width: 130, alignment: .leading)
                            Text(h.mac).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .leading)
                            Text(h.classification).bold().frame(width: 80, alignment: .leading)
                            Text(h.vendor).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if h.classification == "Lutron" {
                                Button("Use as processor") { store.map.processor = h.ip; store.save() }
                            } else if h.classification == "Apple" {
                                Button("Use as Savant host") { store.map.savantHost = h.ip; store.save() }
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.06)))
                    }
                    Text("Match the Lutron row to your processor and the Apple row to the Savant Mac mini.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func color(_ c: String) -> Color {
        switch c { case "Lutron": return .purple; case "Apple": return .blue; default: return .gray }
    }
}
