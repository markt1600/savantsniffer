import SwiftUI

struct ScenesView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient

    @State private var name = ""
    @State private var steps: [CustomMacro.MacroStep] = []
    @State private var runConfirm: CustomMacro?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Custom scenes").font(.largeTitle.bold())
                Text("Build your own macros from captured devices. A scene is an ordered list of steps the app sends: a load to a level, a keypad press, a replayed Savant command, or a pause. Running a scene is gated like any control.")
                    .foregroundStyle(.secondary).font(.callout)

                existing
                Divider()
                builder
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Run scene?", isPresented: Binding(
            get: { runConfirm != nil }, set: { if !$0 { runConfirm = nil } })) {
            Button("Run — this changes hardware", role: .destructive) {
                if let m = runConfirm { Task { await store.runMacro(m, using: lip, confirmed: true) } }
                runConfirm = nil
            }
            Button("Cancel", role: .cancel) { runConfirm = nil }
        } message: {
            Text(runConfirm.map { "\($0.name): \($0.steps.count) steps" } ?? "")
        }
    }

    private var existing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved scenes").font(.title2.bold())
            if (store.map.customMacros ?? []).isEmpty {
                Text("None yet.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(store.map.customMacros ?? []) { m in
                HStack {
                    VStack(alignment: .leading) {
                        Text(m.name).bold()
                        Text("\(m.steps.count) steps").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run") { runConfirm = m }
                        .disabled(lip.state != .monitoring)
                    Button(role: .destructive) { store.deleteMacro(m.id) } label: { Image(systemName: "trash") }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
            }
            if !store.lastRunLog.isEmpty {
                GroupBox("Last run") {
                    VStack(alignment: .leading) {
                        ForEach(store.lastRunLog.indices, id: \.self) { Text(store.lastRunLog[$0]).font(.caption.monospaced()) }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var builder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New scene").font(.title2.bold())
            TextField("scene name (e.g. Movie night)", text: $name).frame(width: 280)

            HStack {
                Button("Add: load to level") { steps.append(.init(type: .output, outputID: firstOutputID(), level: 50)) }
                Button("Add: keypad press") { steps.append(.init(type: .press, keypadID: firstKeypadID(), button: 1)) }
                Button("Add: pause") { steps.append(.init(type: .delay, delayMs: 500)) }
                Button("Add: Savant replay") { steps.append(.init(type: .savant, savantHost: store.map.savantHost, savantPort: 0, savantPayload: "")) }
            }.font(.callout)

            if let effect = lastCaptureEffect(), !effect.isEmpty {
                Button("Import \(effect.count) loads from last macro capture") {
                    for e in effect { steps.append(.init(type: .output, outputID: e.id, level: e.level)) }
                }.font(.callout)
            }

            ForEach($steps) { $step in StepRow(step: $step, store: store) }
                .onDelete { steps.remove(atOffsets: $0) }

            HStack {
                Button("Save scene") {
                    guard !name.isEmpty, !steps.isEmpty else { return }
                    store.addMacro(CustomMacro(name: name, steps: steps))
                    name = ""; steps = []
                }.disabled(name.isEmpty || steps.isEmpty)
                if !steps.isEmpty { Button("Clear") { steps = [] } }
            }
        }
    }

    private func firstOutputID() -> Int? { store.map.areas.flatMap { $0.outputs }.first?.lutronID }
    private func firstKeypadID() -> Int? { store.map.areas.flatMap { $0.keypads }.compactMap { $0.lutronID }.first }
    private func lastCaptureEffect() -> [DeviceMap.Effect]? {
        lip.recorder.steps.isEmpty ? nil : lip.recorder.effect()
    }
}

struct StepRow: View {
    @Binding var step: CustomMacro.MacroStep
    let store: DeviceStore

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $step.type) {
                ForEach(CustomMacro.StepType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.frame(width: 90).labelsHidden()

            switch step.type {
            case .output:
                Picker("", selection: Binding($step.outputID, replacingNilWith: 0)) {
                    ForEach(allOutputs, id: \.0) { Text($0.1).tag($0.0) }
                }.frame(width: 180).labelsHidden()
                Slider(value: Binding($step.level, replacingNilWith: 50), in: 0...100, step: 1).frame(width: 120)
                Text("\(Int(step.level ?? 50))%").monospacedDigit().frame(width: 40)
            case .press:
                Picker("", selection: Binding($step.keypadID, replacingNilWith: 0)) {
                    ForEach(allKeypads, id: \.0) { Text($0.1).tag($0.0) }
                }.frame(width: 180).labelsHidden()
                Stepper("btn \(step.button ?? 1)", value: Binding($step.button, replacingNilWith: 1), in: 1...50).frame(width: 110)
            case .delay:
                Stepper("\(step.delayMs ?? 500) ms", value: Binding($step.delayMs, replacingNilWith: 500), in: 0...10000, step: 100)
            case .savant:
                TextField("host", text: Binding($step.savantHost, replacingNilWith: "")).frame(width: 110)
                TextField("port", value: Binding($step.savantPort, replacingNilWith: 0), format: .number).frame(width: 60)
                TextField("payload (captured command)", text: Binding($step.savantPayload, replacingNilWith: "")).frame(width: 200)
            }
            Spacer()
        }
        .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.05)))
    }

    private var allOutputs: [(Int, String)] {
        store.map.areas.flatMap { a in a.outputs.map { ($0.lutronID, "\(a.name)/\($0.name)") } }
    }
    private var allKeypads: [(Int, String)] {
        store.map.areas.flatMap { a in a.keypads.compactMap { k in k.lutronID.map { ($0, "\(a.name)/\(k.name)") } } }
    }
}

// Binding helper to edit optional values with non-optional controls.
extension Binding {
    init<T>(_ source: Binding<T?>, replacingNilWith def: T) where Value == T {
        self.init(get: { source.wrappedValue ?? def },
                  set: { source.wrappedValue = $0 })
    }
}
