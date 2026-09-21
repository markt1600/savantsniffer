import SwiftUI

struct CoverageView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient
    @State private var note = ""

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Capture coverage",
                           subtitle: "Green is fully captured. Amber is partly captured. Grey is still to do.") {
                    Button("Merge starting layout") {
                        let r = store.mergeSeed()
                        note = "Added \(r.areas) rooms, \(r.keypads) keypads, \(r.buttons) buttons."
                    }
                    Button("Export report…") { exportReport() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(Theme.muted) }

                heroCard

                HStack {
                    Text("By room").font(.system(size: 15, weight: .bold))
                    Spacer()
                    Text("one dot per button · click a room to expand").font(.caption).foregroundStyle(Theme.muted)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.map.areas) { RoomCard(area: $0) }
                }
            }
            .padding(26)
        }
    }

    private func exportReport() {
        note = Exporter.exportViaPanel(store: store, lip: lip)
    }

    private var heroCard: some View {
        let c = store.overallCoverage()
        return Card(padding: 22) {
            HStack(spacing: 22) {
                ZStack {
                    Circle().stroke(Theme.greyTint, lineWidth: 12)
                    Circle().trim(from: 0, to: CGFloat(c.fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int((c.fraction * 100).rounded()))%").font(.system(size: 30, weight: .bold)).monospacedDigit()
                        Text("captured").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(width: 132, height: 132)

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(c.captured) of \(c.total) buttons captured").font(.system(size: 17, weight: .bold))
                    Text("\(store.map.areas.count) rooms · \(store.map.areas.reduce(0) { $0 + $1.keypads.count }) keypads · \(lip.events.count) events this session")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    HStack(spacing: 12) {
                        tile("Captured", c.captured, Theme.green, Theme.greenTint, Theme.greenInk)
                        tile("Partial", c.identified, Theme.amber, Theme.amberTint, Theme.amberInk)
                        tile("Pending", c.pending, Theme.grey, Theme.greyTint, Theme.muted)
                    }.padding(.top, 6)
                }

                Divider().frame(height: 120)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("What we need")
                    need("Lutron processor", store.map.processor?.isEmpty == false, store.map.processor ?? "not found", mono: true)
                    need("System identified", store.map.system?.isEmpty == false, store.map.system ?? "unknown")
                    need("Access working", store.map.accessOK ?? false, (store.map.accessOK ?? false) ? "login OK" : "not yet")
                    need("Savant host", store.map.savantHost?.isEmpty == false, store.map.savantHost ?? "not yet", mono: true)
                }
                .frame(width: 300)
            }
        }
    }

    private func tile(_ title: String, _ value: Int, _ dot: Color, _ bg: Color, _ ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) { LED(color: dot); Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink) }
            Text("\(value)").font(.system(size: 26, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minWidth: 120, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(dot.opacity(0.35), lineWidth: 1))
    }

    private func need(_ label: String, _ ok: Bool, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 10) {
            BoolDot(ok: ok)
            Text(label).font(.system(size: 13))
            Spacer()
            if mono { Text(value).mono(12).foregroundStyle(Theme.muted) }
            else { Text(value).font(.system(size: 12)).foregroundStyle(Theme.muted) }
        }
    }
}

struct RoomCard: View {
    @EnvironmentObject var store: DeviceStore
    let area: DeviceMap.Area
    @State private var expanded = false

    private struct Dot: Identifiable { let id: Int; let status: DeviceMap.CaptureStatus }

    private var dots: [Dot] {
        var out: [Dot] = []
        for kp in area.keypads {
            for b in kp.buttons { out.append(Dot(id: out.count, status: b.status(keypadIdentified: kp.lutronID != nil))) }
        }
        return out
    }

    var body: some View {
        let c = store.coverage(for: area)
        let complete = c.total > 0 && c.captured == c.total
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(area.name.capitalized).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("\(c.captured) / \(c.total)").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                }
                ProgressView(value: c.fraction).tint(complete ? Theme.green : Theme.accent)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 12, maximum: 12), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(dots) { StatusDot(status: $0.status, size: 12) }
                }
                Text(footer(c: c, complete: complete))
                    .font(.system(size: 11.5, weight: complete ? .semibold : .regular))
                    .foregroundStyle(complete ? Theme.greenInk : Theme.muted)
                if expanded {
                    Divider()
                    ForEach(area.keypads) { kp in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kp.name + (kp.lutronID != nil ? " · id \(kp.lutronID!)" : " · id ?"))
                                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
                            ForEach(kp.buttons) { b in
                                HStack(spacing: 8) {
                                    StatusDot(status: b.status(keypadIdentified: kp.lutronID != nil))
                                    Text(b.label).font(.system(size: 12.5)).frame(width: 130, alignment: .leading)
                                    Chip.kind(b.kind)
                                    if let n = b.button { Text("btn \(n)").mono(11).foregroundStyle(Theme.muted) }
                                    if let e = b.effect, !e.isEmpty { Text("· \(e.count) loads").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    }

    private func footer(c: DeviceStore.Coverage, complete: Bool) -> String {
        if complete { return "complete" }
        let ids = area.keypads.compactMap { $0.lutronID }
        let idText = ids.isEmpty ? "keypad id ?" : "keypad id " + ids.map { String($0) }.joined(separator: ", ")
        let macros = area.keypads.flatMap { $0.buttons }.filter { $0.kind == "macro" && ($0.effect?.isEmpty ?? true) }.count
        let savant = area.keypads.flatMap { $0.buttons }.filter { $0.kind == "integration" && !($0.savantCaptured ?? false) }.count
        var parts = [idText]
        if macros > 0 { parts.append("\(macros) scene\(macros == 1 ? "" : "s") to capture") }
        if savant > 0 { parts.append("\(savant) on Savant side") }
        return parts.joined(separator: " · ")
    }
}
