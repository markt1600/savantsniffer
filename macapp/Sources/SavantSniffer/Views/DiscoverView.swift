import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var discovery: DiscoveryModel
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Discover hosts",
                           subtitle: "Scans only your local subnet. What runs is shown before it runs.") {
                    EmptyView()
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .bottom, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Subnet").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                                TextField("192.168.1.0/24", text: $discovery.subnet).textFieldStyle(.roundedBorder).mono(13).frame(width: 180)
                                    .onChange(of: discovery.subnet) { _ in discovery.buildCommand() }
                            }
                            Button(discovery.scanning ? (discovery.progress.isEmpty ? "Scanning…" : discovery.progress) : "Run built-in sweep") {
                                discovery.runSweep()
                            }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(discovery.scanning)
                            if let cmd = discovery.privilegedCommand {
                                Button("Run \(cmd.contains("arp-scan") ? "arp-scan" : "nmap") instead (admin prompt)") { discovery.runPrivileged() }
                                    .disabled(discovery.scanning)
                            }
                        }
                        Text(discovery.scanCommand).mono(12).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink)).foregroundStyle(.white)
                        Text(discovery.note).font(.caption).foregroundStyle(Theme.muted)
                        ScanProgress()
                        if let err = discovery.lastError { Text(err).font(.caption).foregroundStyle(Theme.red) }
                    }
                }

                if !discovery.hosts.isEmpty {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Results").font(.system(size: 13, weight: .bold))
                                Spacer()
                                Text("\(discovery.hosts.count) hosts · Lutron and Savant candidates first").font(.caption).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10).background(Theme.greyTint)
                            Divider()
                            ForEach(discovery.hosts) { h in
                                HStack(spacing: 12) {
                                    LED(color: color(h.classification))
                                    Text(h.ip).mono(12.5).frame(width: 118, alignment: .leading)
                                    Text(h.mac).mono(11.5).foregroundStyle(Theme.muted).frame(width: 140, alignment: .leading)
                                    Text(h.classification == "other" || h.classification == "unknown" ? (h.vendor.isEmpty ? "unknown" : h.vendor) : h.classification)
                                        .font(.system(size: 12.5, weight: .semibold)).frame(width: 150, alignment: .leading).lineLimit(1)
                                    HStack(spacing: 6) {
                                        if h.lipLogin { Chip(text: "LIP LOGIN", bg: Theme.amberTint, fg: Theme.amberInk) }
                                        else if h.lipOpen { Chip(text: "PORT 23", bg: Theme.greyTint, fg: Theme.muted) }
                                        if h.leapOpen { Chip(text: "TLS 8081", bg: Theme.purpleTint, fg: Theme.purple) }
                                        if !h.tlsSubject.isEmpty { Text("cert: \(h.tlsSubject)").font(.caption).foregroundStyle(Theme.purple).lineLimit(1) }
                                        else if h.lipOpen && !h.banner.isEmpty { Text("says: \(h.banner)").font(.caption).foregroundStyle(Theme.muted).lineLimit(1) }
                                        else if h.lipOpen { Text("silent on connect").font(.caption).foregroundStyle(Theme.muted) }
                                    }
                                    Spacer()
                                    if h.isLutronCandidate {
                                        Button(store.map.processor == h.ip ? "✓ processor" : "Use as processor") { store.map.processor = h.ip; store.save() }
                                            .controlSize(.small).disabled(store.map.processor == h.ip)
                                    }
                                    if h.isSavantCandidate {
                                        Button(store.map.savantHost == h.ip ? "✓ Savant host" : "Use as Savant host") { store.map.savantHost = h.ip; store.save() }
                                            .controlSize(.small).disabled(store.map.savantHost == h.ip)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .overlay(Divider(), alignment: .bottom)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("LIP LOGIN = answered on port 23 with a login prompt, the Lutron processor's signature. PORT 23 alone is usually AV gear (Denon/Marantz use telnet without a prompt). TLS 8081 shows the name on the device's certificate: a Lutron LEAP processor says so; a Lutron Connect Bridge (RadioRA 2 / HomeWorks QS app bridge) also answers here but cannot be paired. Private = a phone or laptop with a randomised address.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Optional tools").font(.system(size: 13, weight: .bold))
                        ForEach(discovery.tools, id: \.name) { t in
                            HStack(spacing: 10) {
                                BoolDot(ok: t.present)
                                Text(t.name).font(.system(size: 12.5)).frame(width: 80, alignment: .leading)
                                Text(t.present ? (t.path ?? "") : "install: \(t.hint)").font(.caption).foregroundStyle(Theme.muted)
                                Spacer()
                            }
                        }
                        Text("None are required. The built-in sweep finds the processor without them.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(26)
        }
    }

    private func color(_ c: String) -> Color {
        switch c {
        case "Lutron": return Theme.purple
        case "Savant", "Apple": return Theme.blue
        case "Denon/Marantz", "Sonos", "Hue": return Theme.amber
        case "Ubiquiti": return Theme.accent
        default: return Theme.grey
        }
    }
}
