import SwiftUI

struct CoverageView: View {
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Capture coverage").font(.largeTitle.bold())
                Text("Green means fully captured. Yellow means partially captured (button seen, but its scene burst or Savant command still to do). Grey means not captured yet.")
                    .foregroundStyle(.secondary).font(.callout)

                checklist
                overall
                Divider()
                rooms
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var checklist: some View {
        GroupBox("What we need") {
            VStack(alignment: .leading, spacing: 8) {
                row("Lutron processor IP found", store.map.processor?.isEmpty == false)
                row("System identified (LIP or LEAP)", store.map.system?.isEmpty == false)
                row("Access working (LIP login or LEAP pairing)", store.map.accessOK ?? false)
                row("Savant host IP (for AV / music capture)", store.map.savantHost?.isEmpty == false)
            }.padding(6)
        }
    }

    private func row(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 10) { BoolDot(ok: ok); Text(label); Spacer() }
    }

    private var overall: some View {
        let c = store.overallCoverage()
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Overall: \(c.captured) of \(c.total) buttons captured")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(c.fraction * 100))%").font(.headline).monospacedDigit()
                }
                ProgressView(value: c.fraction)
                HStack(spacing: 16) {
                    legend(.captured, "captured \(c.captured)")
                    legend(.identified, "partial \(c.identified)")
                    legend(.pending, "pending \(c.pending)")
                }.font(.caption)
            }.padding(6)
        }
    }

    private func legend(_ s: DeviceMap.CaptureStatus, _ text: String) -> some View {
        HStack(spacing: 6) { StatusDot(status: s); Text(text) }
    }

    private var rooms: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By room").font(.title2.bold())
            ForEach(store.map.areas) { area in
                RoomCoverageRow(area: area)
            }
        }
    }
}

struct RoomCoverageRow: View {
    @EnvironmentObject var store: DeviceStore
    let area: DeviceMap.Area
    @State private var expanded = false

    var body: some View {
        let c = store.coverage(for: area)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }.buttonStyle(.plain)
                Text(area.name.capitalized).frame(width: 180, alignment: .leading)
                ProgressView(value: c.fraction).frame(width: 140)
                Text("\(c.captured)/\(c.total)").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }
            if expanded {
                ForEach(area.keypads) { kp in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kp.name + (kp.lutronID != nil ? "  (id \(kp.lutronID!))" : "  (id ?)"))
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(kp.buttons) { b in
                            HStack(spacing: 8) {
                                StatusDot(status: b.status(keypadIdentified: kp.lutronID != nil))
                                Text(b.label).frame(width: 150, alignment: .leading)
                                Text(b.kind).font(.caption).foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                if let n = b.button { Text("btn \(n)").font(.caption).monospacedDigit() }
                                Spacer()
                            }.padding(.leading, 20)
                        }
                    }.padding(.leading, 28).padding(.vertical, 2)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }
}
