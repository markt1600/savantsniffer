import SwiftUI
import AppKit

/// Guide step 1: pick the copied RacePointMedia folder and import it.
struct SavantImportCard: View {
    @EnvironmentObject var store: DeviceStore
    @State private var note = ""
    @State private var working = false

    private var info: DeviceMap.SavantInfo? { store.map.savant }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(working ? "Reading…" : (info == nil ? "Choose folder and import…" : "Import again…")) { pick() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(working)
                Text("read-only · nothing leaves this Mac · the Savant host is not touched").font(.caption).foregroundStyle(Theme.muted)
            }
            Text("Copy ~/Library/Application Support/RacePointMedia from the Mac mini (or at least userConfig.rpmConfig, lighting/shm and statusfiles) to a drive, then pick that folder here.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if !note.isEmpty { Text(note).font(.system(size: 12.5)).foregroundStyle(note.hasPrefix("Imported") ? Theme.greenInk : Theme.red) }
            if let i = info { summary(i) }
        }
    }

    private func summary(_ i: DeviceMap.SavantInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LED(color: Theme.green, glow: true)
                Text("Imported \(i.importedAt ?? "")").font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                row("Lighting", "Lutron, driven over LEAP by Savant's LEAP Integration Bridge")
                row("Savant bridge", "\(i.bridgeIP ?? "?")  ·  MAC \(i.bridgeMAC ?? "?")  (rpe-am335x; leave it alone)")
                row("Lutron processor", "MAC \(i.processorMAC ?? "unknown")  ·  the host with TLS 8081 carrying this MAC")
                if let c = i.counts {
                    row("Imported", "\(c["rooms"] ?? 0) rooms · \(c["buttons"] ?? 0) keypad buttons · \(c["loads"] ?? 0) loads · \(c["shades"] ?? 0) shade groups · \(c["workflows"] ?? 0) workflows · \(c["devices"] ?? 0) AV devices")
                }
            }
            if let z = i.audioZones, !z.isEmpty {
                SectionLabel("Audio zones")
                ForEach(z.keys.sorted(), id: \.self) { k in
                    HStack(spacing: 6) { Text(k).mono(11); Text("→").foregroundStyle(Theme.muted); Text(z[k] ?? "").font(.system(size: 11.5)) }
                }
            }
            if let d = i.devices, !d.isEmpty {
                SectionLabel("Devices Savant controls")
                ForEach(d) { dev in
                    HStack(spacing: 8) {
                        Text(dev.name).font(.system(size: 11.5, weight: .medium)).frame(width: 170, alignment: .leading).lineLimit(1)
                        Text(dev.room).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(dev.ip.isEmpty ? "" : "\(dev.ip):\(dev.port)").mono(11)
                        Text(dev.protocolHint).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        Spacer()
                    }
                }
            }
            if let n = i.notes, !n.isEmpty {
                ForEach(n, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.amberInk) }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.greyTint))
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            Text(v).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the copied RacePointMedia folder (or the folder containing userConfig.rpmConfig)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        note = "Reading \(url.lastPathComponent)…"
        let result = store.importSavant(folder: url)
        working = false
        note = result
    }
}
