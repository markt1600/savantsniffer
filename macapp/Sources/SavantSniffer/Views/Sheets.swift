import SwiftUI

struct LabelSheet: View {
    @EnvironmentObject var store: DeviceStore
    @Environment(\.dismiss) var dismiss
    let event: MonitorEvent

    @State private var area = ""
    @State private var keypad = ""
    @State private var buttonLabel = ""
    @State private var loadName = ""
    @State private var loadKind = "dimmer"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(event.kind == .device ? "Label this button press" : "Name this load").font(.title2.bold())
            Text(event.raw).mono(13).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.greyTint))
            Text(hint).font(.caption).foregroundStyle(Theme.muted)

            Picker("Room", selection: $area) {
                Text("—").tag("")
                ForEach(store.map.areas) { a in Text(a.name.capitalized).tag(a.name) }
            }
            .onChange(of: area) { _ in keypad = ""; buttonLabel = "" }

            if event.kind == .device {
                Picker("Keypad", selection: $keypad) {
                    Text("—").tag("")
                    ForEach(keypads, id: \.name) { k in Text(k.name).tag(k.name) }
                }
                .onChange(of: keypad) { _ in buttonLabel = "" }
                .disabled(area.isEmpty)
                Picker("Button", selection: $buttonLabel) {
                    Text("—").tag("")
                    ForEach(buttons, id: \.label) { b in Text("\(b.label)  (\(b.kind))").tag(b.label) }
                }
                .disabled(keypad.isEmpty)
            } else {
                TextField("Load name (e.g. island pendants)", text: $loadName).textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $loadKind) {
                    Text("dimmer").tag("dimmer"); Text("switch").tag("switch"); Text("shade").tag("shade")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save to map") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!canSave)
            }
        }
        .padding(20).frame(width: 460)
    }

    private var hint: String {
        if event.kind == .device {
            return "Keypad id \(event.integrationID.map { String($0) } ?? "?"), button \(event.component.map { String($0) } ?? "?"). Pick which mapped button this press is."
        }
        return "Output id \(event.integrationID.map { String($0) } ?? "?") at \(event.level.map { String(format: "%g", $0) } ?? "?")%. Give it a name so you can control it by name."
    }
    private var keypads: [DeviceMap.Keypad] { store.map.areas.first { $0.name == area }?.keypads ?? [] }
    private var buttons: [DeviceMap.Button] { keypads.first { $0.name == keypad }?.buttons ?? [] }
    private var canSave: Bool {
        if event.kind == .device { return !area.isEmpty && !keypad.isEmpty && !buttonLabel.isEmpty }
        return !area.isEmpty && !loadName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        if event.kind == .device, let kid = event.integrationID, let b = event.component {
            store.recordPress(area: area, keypad: keypad, buttonLabel: buttonLabel,
                              lutronKeypadID: kid, buttonNumber: b)
        } else if event.kind == .output, let oid = event.integrationID {
            store.addOutput(area: area, name: loadName.trimmingCharacters(in: .whitespaces), lutronID: oid, kind: loadKind)
        }
        dismiss()
    }
}

struct MacroSaveSheet: View {
    @EnvironmentObject var store: DeviceStore
    @ObservedObject var recorder: MacroRecorder
    @Environment(\.dismiss) var dismiss

    @State private var area = ""
    @State private var keypad = ""
    @State private var buttonLabel = ""
    @State private var zonesText = ""
    @State private var sourceText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save captured button").font(.title2.bold())
            let guess = recorder.classify()
            Text("Detected: \(guess) · \(recorder.steps.count) events · \(recorder.loadsAffected) loads"
                 + (guess == "integration" ? " · no Lutron output, so this is a Savant-side integration" : ""))
                .font(.callout).foregroundStyle(Theme.muted)
            if recorder.triggerDevice == nil {
                Label("No keypad press was seen. Arm capture before pressing next time. The load levels will still be saved.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.amberInk)
            }

            Picker("Room", selection: $area) {
                Text("—").tag("")
                ForEach(store.map.areas) { a in Text(a.name.capitalized).tag(a.name) }
            }
            .onChange(of: area) { _ in keypad = ""; buttonLabel = "" }
            Picker("Keypad", selection: $keypad) {
                Text("—").tag("")
                ForEach(keypads, id: \.name) { k in Text(k.name).tag(k.name) }
            }
            .onChange(of: keypad) { _ in buttonLabel = "" }
            .disabled(area.isEmpty)
            Picker("Button", selection: $buttonLabel) {
                Text("—").tag("")
                ForEach(buttons, id: \.label) { b in Text(b.label).tag(b.label) }
            }
            .disabled(keypad.isEmpty)

            if recorder.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Savant side (optional)")
                    TextField("Audio zones it drives, comma separated (e.g. hallway, living)", text: $zonesText)
                        .textFieldStyle(.roundedBorder)
                    TextField("Audio source (e.g. home office input)", text: $sourceText)
                        .textFieldStyle(.roundedBorder)
                    Text("Fill these in once you've correlated the press with Savant's traffic (Credentials & LEAP → Savant capture).")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }

            HStack {
                Spacer()
                Button("Discard") { recorder.finish(); dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(area.isEmpty || keypad.isEmpty || buttonLabel.isEmpty
                              || (recorder.triggerDevice == nil && recorder.steps.isEmpty))
            }
        }
        .padding(20).frame(width: 460)
    }

    private var keypads: [DeviceMap.Keypad] { store.map.areas.first { $0.name == area }?.keypads ?? [] }
    private var buttons: [DeviceMap.Button] { keypads.first { $0.name == keypad }?.buttons ?? [] }

    private func save() {
        let effect = recorder.effect()
        if let kid = recorder.triggerDevice, let b = recorder.triggerButton {
            store.recordPress(area: area, keypad: keypad, buttonLabel: buttonLabel,
                              lutronKeypadID: kid, buttonNumber: b)
            if effect.isEmpty {
                let zones = zonesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                store.markSavantCaptured(area: area, keypad: keypad, buttonLabel: buttonLabel,
                                         note: zones.isEmpty ? "no Lutron output; correlate with Savant traffic" : "audio zones recorded",
                                         zones: zones, source: sourceText.isEmpty ? nil : sourceText)
            }
        }
        if !effect.isEmpty {
            store.recordMacroEffect(area: area, keypad: keypad, buttonLabel: buttonLabel, effect: effect)
        }
        recorder.finish()
        dismiss()
    }
}
