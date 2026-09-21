import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var discovery: DiscoveryModel
    @EnvironmentObject var store: DeviceStore
    @State private var showCommand = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Discover hosts",
                           subtitle: "Scans only your local subnet. The exact command is shown first and runs only after you approve it.") {
                    EmptyView()
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tools on this Mac").font(.system(size: 13, weight: .bold))
                        ForEach(discovery.tools, id: \.name) { t in
                            HStack(spacing: 10) {
                                BoolDot(ok: t.present)
                                Text(t.name).font(.system(size: 13)).frame(width: 80, alignment: .leading)
                                Text(t.present ? (t.path ?? "") : "install: \(t.hint)").font(.caption).foregroundStyle(Theme.muted)
                                Spacer()
                            }
                        }
                        Text("Nothing is installed automatically.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Subnet").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                                TextField("192.168.1.0/24", text: $discovery.subnet).textFieldStyle(.roundedBorder).mono(13).frame(width: 180)
                                    .onChange(of: discovery.subnet) { _ in discovery.buildCommand() }
                            }
                            Button("Show scan command") { discovery.buildCommand(); showCommand = true }
                        }
                        if showCommand {
                            Text(discovery.scanCommand).mono(12.5).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink)).foregroundStyle(.white)
                            Text(discovery.note).font(.caption).foregroundStyle(Theme.muted)
                            Button(discovery.scanning ? "Scanning…" : "I approve — run this scan") { discovery.runScan() }
                                .buttonStyle(.borderedProminent).tint(Theme.accent)
                                .disabled(discovery.scanning)
                        }
                        if let err = discovery.lastError { Text(err).font(.caption).foregroundStyle(Theme.red) }
                    }
                }
                if !discovery.hosts.isEmpty {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Results").font(.system(size: 13, weight: .bold))
                                Spacer()
                                Text("\(discovery.hosts.count) hosts · Lutron and Apple first").font(.caption).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10).background(Theme.greyTint)
                            Divider()
                            ForEach(discovery.hosts) { h in
                                HStack(spacing: 12) {
                                    LED(color: color(h.classification))
                                    Text(h.ip).mono(12.5).frame(width: 130, alignment: .leading)
                                    Text(h.mac).mono(11.5).foregroundStyle(Theme.muted).frame(width: 150, alignment: .leading)
                                    Text(h.classification).font(.system(size: 12.5, weight: .semibold)).frame(width: 80, alignment: .leading)
                                    Text(h.vendor).font(.caption).foregroundStyle(Theme.muted)
                                    Spacer()
                                    if h.classification == "Lutron" {
                                        Button("Use as processor") { store.map.processor = h.ip; store.save() }.controlSize(.small)
                                    } else if h.classification == "Apple" {
                                        Button("Use as Savant host") { store.map.savantHost = h.ip; store.save() }.controlSize(.small)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .overlay(Divider(), alignment: .bottom)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(26)
        }
    }

    private func color(_ c: String) -> Color {
        switch c { case "Lutron": return Theme.purple; case "Apple": return Theme.blue; default: return Theme.grey }
    }
}
