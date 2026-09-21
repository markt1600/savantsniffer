import SwiftUI

struct MapView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var mergeResult = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Device map").font(.largeTitle.bold())
                    Spacer()
                    Button("Merge starting layout") {
                        let r = store.mergeSeed()
                        mergeResult = "added \(r.areas) rooms, \(r.keypads) keypads, \(r.buttons) buttons"
                    }
                }
                if !mergeResult.isEmpty { Text(mergeResult).font(.caption).foregroundStyle(.secondary) }
                Text("system: \(store.map.system ?? "?")  ·  processor: \(store.map.processor ?? "?")  ·  savant: \(store.map.savantHost ?? "?")")
                    .font(.callout).foregroundStyle(.secondary)

                ForEach(store.map.areas) { area in
                    GroupBox(area.name.capitalized) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(area.keypads) { kp in
                                Text(kp.name + (kp.lutronID != nil ? " · id \(kp.lutronID!)" : " · id ?"))
                                    .font(.callout.bold())
                                ForEach(kp.buttons) { b in
                                    HStack(spacing: 8) {
                                        StatusDot(status: b.status(keypadIdentified: kp.lutronID != nil))
                                        Text(b.label).frame(width: 150, alignment: .leading)
                                        Text(b.kind).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                                        if let n = b.button { Text("btn \(n)").font(.caption.monospaced()) }
                                        if let e = b.effect, !e.isEmpty { Text("· \(e.count) loads").font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                    }
                                }
                            }
                            if !area.outputs.isEmpty {
                                Text("outputs").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                                ForEach(area.outputs) { o in
                                    Text("• \(o.name) · id \(o.lutronID) (\(o.kind))").font(.caption)
                                }
                            }
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
