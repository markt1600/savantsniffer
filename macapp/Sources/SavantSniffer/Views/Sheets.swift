import SwiftUI

struct LabelSheet: View {
    @EnvironmentObject var store: DeviceStore
    @Environment(\.dismiss) var dismiss
    let event: MonitorEvent

    @State private var area = ""
    @State private var keypad = ""
    @State private var buttonLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Label this event").font(.title2.bold())
            Text(event.raw).font(.system(.body, design: .monospaced))
                .padding(6).background(Color.gray.opacity(0.1)).cornerRadius(6)
            Text(hint).font(.caption).foregroundStyle(.secondary)

            Picker("Room", selection: $area) {
                Text("—").tag("")
                ForEach(store.map.areas) { a in Text(a.name.capitalized).tag(a.name) }
            }.onChange(of: area) { _ in keypad = ""; buttonLabel = "" }

            Picker("Keypad", selection: $keypad) {
                Text("—").tag("")
                ForEach(keypads, id: \.name) { k in Text(k.name).tag(k.name) }
            }.onChange(of: keypad) { _ in buttonLabel = "" }.disabled(area.isEmpty)

            Picker("Button", selection: $buttonLabel) {
                Text("—").tag("")
                ForEach(buttons, id: \.label) { b in
                    Text("\(b.label)  (\(b.kind))").tag(b.label)
                }
            }.disabled(keypad.isEmpty)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save to map") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(area.isEmpty || keypad.isEmpty || buttonLabel.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }

    private var hint: String {
        if event.kind == .device {
            return "Keypad id \(event.integrationID.map(String.init) ?? "?"), button \(event.component.map(String.init) ?? "?"). Pick which mapped button this press is."
        }
        return "Output id \(event.integrationID.map(String.init) ?? "?") at level \(event.level.map{String(format:"%g",$0)} ?? "?"). Attach it to a load if you want to control it by name."
    }
    private var keypads: [DeviceMap.Keypad] {
        store.map.areas.first { $0.name == area }?.keypads ?? []
    }
    private var buttons: [DeviceMap.Button] {
        keypads.first { $0.name == keypad }?.buttons ?? []
    }

    private func save() {
        if event.kind == .device, let kid = event.integrationID, let b = event.component {
            store.recordPress(area: area, keypad: keypad, buttonLabel: buttonLabel,
                              lutronKeypadID: kid, buttonNumber: b)
        } else if event.kind == .output, let oid = event.integrationID {
            // attach as an output the button controls; also add a named output to the area
            if let ai = store.map.areas.firstIndex(where: { $0.name == area }),
               !store.map.areas[ai].outputs.contains(where: { $0.lutronID == oid }) {
                store.map.areas[ai].outputs.append(
                    DeviceMap.Output(name: buttonLabel, lutronID: oid, kind: "dimmer"))
                store.save()
            }
        }
        dismiss()
    }
}

struct MacroSaveSheet: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient
    @Environment(\.dismiss) var dismiss

    @State private var area = ""
    @State private var keypad = ""
    @State private var buttonLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save captured button").font(.title2.bold())
            let guess = lip.recorder.classify()
            let ids = Set(lip.recorder.steps.map { $0.id })
            Text("Detected type: \(guess) · \(lip.recorder.steps.count) events · \(ids.count) loads affected"
                 + (guess == "integration" ? " (no Lutron output — a Savant/Spotify integration)" : ""))
                .font(.callout).foregroundStyle(.secondary)

            Picker("Room", selection: $area) {
                Text("—").tag("")
                ForEach(store.map.areas) { a in Text(a.name.capitalized).tag(a.name) }
            }.onChange(of: area) { _ in keypad = ""; buttonLabel = "" }
            Picker("Keypad", selection: $keypad) {
                Text("—").tag("")
                ForEach(keypads, id: \.name) { k in Text(k.name).tag(k.name) }
            }.disabled(area.isEmpty)
            Picker("Button", selection: $buttonLabel) {
                Text("—").tag("")
                ForEach(buttons, id: \.label) { b in Text(b.label).tag(b.label) }
            }.disabled(keypad.isEmpty)

            HStack {
                Spacer()
                Button("Discard") { lip.recorder.finish(); dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(area.isEmpty || keypad.isEmpty || buttonLabel.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }

    private var keypads: [DeviceMap.Keypad] { store.map.areas.first { $0.name == area }?.keypads ?? [] }
    private var buttons: [DeviceMap.Button] { keypads.first { $0.name == keypad }?.buttons ?? [] }

    private func save() {
        if let kid = lip.recorder.triggerDevice, let b = lip.recorder.triggerButton {
            store.recordPress(area: area, keypad: keypad, buttonLabel: buttonLabel,
                              lutronKeypadID: kid, buttonNumber: b)
        }
        let effect = lip.recorder.effect()
        if !effect.isEmpty {
            store.recordMacroEffect(area: area, keypad: keypad, buttonLabel: buttonLabel, effect: effect)
        } else {
            store.markSavantCaptured(area: area, keypad: keypad, buttonLabel: buttonLabel,
                                     note: "no Lutron output; capture Savant traffic for this button")
        }
        lip.recorder.finish()
        dismiss()
    }
}
