import SwiftUI

struct ControlView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient

    @State private var outputSel = ""     // "area/name"
    @State private var level = 50.0
    @State private var confirmSet = false
    @State private var keypadSel = ""     // "area/keypad"
    @State private var button = 1
    @State private var confirmPress = false
    @State private var log: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Control").font(.largeTitle.bold())
                if lip.state != .monitoring {
                    Label("Connect on the Monitor tab first. Control needs the live session.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("Observe-first: every action needs its confirm box ticked. Each press sends a real command.")
                    .foregroundStyle(.secondary).font(.callout)

                GroupBox("Set a load level") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Load", selection: $outputSel) {
                            Text("—").tag("")
                            ForEach(outputs, id: \.self) { Text($0).tag($0) }
                        }
                        HStack {
                            Slider(value: $level, in: 0...100, step: 1).frame(width: 240)
                            Text("\(Int(level))%").monospacedDigit().frame(width: 44)
                        }
                        Toggle("I confirm this changes hardware", isOn: $confirmSet)
                        Button("Send set") { doSet() }
                            .disabled(outputSel.isEmpty || !confirmSet || lip.state != .monitoring)
                    }.padding(6)
                }

                GroupBox("Press a keypad button") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Keypad", selection: $keypadSel) {
                            Text("—").tag("")
                            ForEach(keypadKeys, id: \.self) { Text($0).tag($0) }
                        }
                        Stepper("Button \(button)", value: $button, in: 1...50)
                        Toggle("I confirm this changes hardware", isOn: $confirmPress)
                        Button("Send press") { doPress() }
                            .disabled(keypadSel.isEmpty || !confirmPress || lip.state != .monitoring)
                    }.padding(6)
                }

                if !log.isEmpty {
                    GroupBox("Sent") {
                        VStack(alignment: .leading) {
                            ForEach(log.indices, id: \.self) { Text(log[$0]).font(.caption.monospaced()) }
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outputs: [String] {
        store.map.areas.flatMap { a in a.outputs.map { "\(a.name)/\($0.name)" } }
    }
    private var keypadKeys: [String] {
        store.map.areas.flatMap { a in a.keypads.compactMap { $0.lutronID != nil ? "\(a.name)/\($0.name)" : nil } }
    }

    private func outputID(for key: String) -> Int? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return store.map.areas.first { $0.name == parts[0] }?
            .outputs.first { $0.name == parts[1] }?.lutronID
    }
    private func keypadID(for key: String) -> Int? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return store.map.areas.first { $0.name == parts[0] }?
            .keypads.first { $0.name == parts[1] }?.lutronID
    }

    private func doSet() {
        guard let id = outputID(for: outputSel) else { return }
        let cmd = String(format: "#OUTPUT,%d,1,%g", id, level)
        let ok = lip.sendControl(cmd, confirmed: true)
        log.append((ok ? "sent " : "blocked ") + cmd)
        confirmSet = false
    }
    private func doPress() {
        guard let id = keypadID(for: keypadSel) else { return }
        let cmd = "#DEVICE,\(id),\(button),3"
        let ok = lip.sendControl(cmd, confirmed: true)
        log.append((ok ? "sent " : "blocked ") + cmd)
        confirmPress = false
    }
}
