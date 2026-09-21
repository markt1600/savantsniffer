import SwiftUI

struct ScenesView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient

    @State private var name = ""
    @State private var steps: [CustomMacro.MacroStep] = []
    @State private var runConfirm: CustomMacro?
    @State private var cloneKey = ""

    private struct CloneSource: Identifiable { let id: String; let title: String; let effect: [DeviceMap.Effect] }
    private var cloneSources: [CloneSource] {
        var out: [CloneSource] = []
        for a in store.map.areas {
            for k in a.keypads {
                for b in k.buttons {
                    if let e = b.effect, !e.isEmpty {
                        out.append(CloneSource(id: "\(a.name)|\(k.name)|\(b.label)",
                                               title: "\(a.name.capitalized) · \(b.label) (\(e.count) loads)", effect: e))
                    }
                }
            }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Custom scenes",
                           subtitle: "Your own macros, built from captured devices. Change any level or add a fade. Running one is gated like any control.") {
                    EmptyView()
                }
                HStack(alignment: .top, spacing: 16) {
                    savedColumn.frame(width: 330)
                    builderCard
                }
            }
            .padding(26)
        }
        .confirmationDialog("Run this scene?",
                            isPresented: Binding(get: { runConfirm != nil }, set: { if !$0 { runConfirm = nil } }),
                            titleVisibility: .visible) {
            Button("Run — this changes hardware", role: .destructive) {
                if let m = runConfirm { Task { await store.runMacro(m, using: lip, confirmed: true) } }
                runConfirm = nil
            }
            Button("Cancel", role: .cancel) { runConfirm = nil }
        } message: {
            Text(runConfirm.map { "\($0.name): \($0.steps.count) steps will be sent." } ?? "")
        }
    }

    // MARK: saved

    private var savedColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Saved scenes")
            if (store.map.customMacros ?? []).isEmpty {
                Text("None yet. Build one on the right.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            ForEach(store.map.customMacros ?? []) { m in
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(m.name).font(.system(size: 14, weight: .bold))
                            Spacer()
                            Text("\(m.steps.count) steps").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                        HStack(spacing: 6) {
                            ForEach(CustomMacro.StepType.allCases, id: \.self) { t in
                                let n = m.steps.filter { $0.type == t }.count
                                if n > 0 { Chip.kind(t.rawValue).overlay(Text("\(n) \(t.rawValue)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.clear)) }
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Run") { runConfirm = m }
                                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                                .disabled(!lip.isLive)
                            Button("Edit") { name = m.name; steps = m.steps }.controlSize(.small)
                            Button(role: .destructive) { store.deleteMacro(m.id) } label: { Image(systemName: "trash") }
                                .controlSize(.small)
                        }
                    }
                }
            }
            if !store.lastRunLog.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last run").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.muted)
                    ForEach(store.lastRunLog.indices, id: \.self) { i in
                        Text(store.lastRunLog[i]).mono(11.5).foregroundStyle(Theme.muted)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.greyTint))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
        }
    }

    // MARK: builder

    private var builderCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scene name").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        TextField("e.g. Evening wind-down", text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    Spacer()
                    ImportCaptureButton(recorder: lip.recorder) { appendOutputs($0) }
                    Button("Save scene") { save() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || steps.isEmpty)
                }

                HStack(spacing: 8) {
                    SectionLabel("Build from a captured button")
                    Picker("", selection: $cloneKey) {
                        Text("choose…").tag("")
                        ForEach(cloneSources) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 300)
                    Button("Clone its loads") {
                        if let src = cloneSources.first(where: { $0.id == cloneKey }) { appendOutputs(src.effect) }
                    }
                    .disabled(cloneKey.isEmpty)
                    Text("then change the levels or fades").font(.caption).foregroundStyle(Theme.muted)
                }

                HStack(spacing: 8) {
                    SectionLabel("Add step")
                    Button("Load to level") { steps.append(.init(type: .output, outputID: firstOutputID(), level: 50)) }
                    Button("Keypad press") { steps.append(.init(type: .press, keypadID: firstKeypadID(), button: 1)) }
                    Button("Savant replay") { steps.append(.init(type: .savant, savantHost: store.map.savantHost, savantPort: 0, savantPayload: "")) }
                    Button("Pause") { steps.append(.init(type: .delay, delayMs: 500)) }
                }
                .controlSize(.small)

                VStack(spacing: 8) {
                    ForEach($steps) { $step in
                        StepRow(store: store, step: $step,
                                index: (steps.firstIndex { $0.id == step.id } ?? 0) + 1) {
                            steps.removeAll { $0.id == step.id }
                        }
                    }
                }

                if !steps.isEmpty { willSend }
            }
        }
    }

    private var willSend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WILL SEND").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                Text("\(steps.count) steps").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6))
            }
            ForEach(steps) { s in
                Text(CustomMacro.previewLine(for: s)).mono(12)
                    .foregroundStyle(s.type == .savant ? Color(red: 0.77, green: 0.71, blue: 0.99) : (s.type == .delay ? Color.white.opacity(0.6) : .white))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ink))
    }

    private func appendOutputs(_ effect: [DeviceMap.Effect]) {
        for e in effect { steps.append(.init(type: .output, outputID: e.id, level: e.level)) }
    }
    private func firstOutputID() -> Int? { store.map.areas.flatMap { $0.outputs }.first?.lutronID }
    private func firstKeypadID() -> Int? { store.map.areas.flatMap { $0.keypads }.compactMap { $0.lutronID }.first }
    private func save() {
        store.addMacro(CustomMacro(name: name.trimmingCharacters(in: .whitespaces), steps: steps))
        name = ""; steps = []
    }
}

struct ImportCaptureButton: View {
    @ObservedObject var recorder: MacroRecorder
    var onImport: ([DeviceMap.Effect]) -> Void
    private var effect: [DeviceMap.Effect] { recorder.effect() }
    var body: some View {
        Button("Import last capture (\(effect.count) loads)") { onImport(effect) }
            .disabled(effect.isEmpty)
    }
}

struct StepRow: View {
    @ObservedObject var store: DeviceStore
    @Binding var step: CustomMacro.MacroStep
    var index: Int
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.muted)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.greyTint))
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            Picker("", selection: $step.type) {
                ForEach(CustomMacro.StepType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 96)

            switch step.type {
            case .output:
                Picker("", selection: Binding($step.outputID, replacingNilWith: 0)) {
                    ForEach(allOutputs, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 190)
                Slider(value: Binding($step.level, replacingNilWith: 50), in: 0...100, step: 1).frame(width: 130)
                Text("\(Int(step.level ?? 50))%").monospacedDigit().frame(width: 40, alignment: .leading)
                TextField("fade", value: Binding($step.fadeSeconds, replacingNilWith: 0), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 52)
                Text("s fade").font(.caption).foregroundStyle(Theme.muted)
            case .press:
                Picker("", selection: Binding($step.keypadID, replacingNilWith: 0)) {
                    ForEach(allKeypads, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 190)
                Stepper("button \(step.button ?? 1)", value: Binding($step.button, replacingNilWith: 1), in: 1...50).frame(width: 120)
            case .delay:
                Stepper("\(step.delayMs ?? 500) ms", value: Binding($step.delayMs, replacingNilWith: 500), in: 0...10000, step: 100)
            case .savant:
                TextField("host", text: Binding($step.savantHost, replacingNilWith: "")).textFieldStyle(.roundedBorder).frame(width: 120)
                TextField("port", value: Binding($step.savantPort, replacingNilWith: 0), format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
                TextField("payload (captured command)", text: Binding($step.savantPayload, replacingNilWith: "")).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "xmark") }
                .controlSize(.small)
                .accessibilityLabel("Remove step")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
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
