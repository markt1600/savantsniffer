import SwiftUI

struct ControlView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient

    @State private var outputSel = ""
    @State private var level = 50.0
    @State private var fade = 0.0
    @State private var confirmSet = false
    @State private var keypadSel = ""
    @State private var button = 1
    @State private var confirmPress = false
    @State private var log: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Control",
                           subtitle: "Observe-first: every action needs its confirm box ticked. Each send is a real command.") {
                    EmptyView()
                }
                if !lip.isLive {
                    Label("Connect on the Monitor screen first. Control uses the live session.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.amberInk)
                }
                HStack(alignment: .top, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Set a load level").font(.system(size: 13, weight: .bold))
                            Picker("Load", selection: $outputSel) {
                                Text("—").tag("")
                                ForEach(outputs, id: \.self) { Text($0).tag($0) }
                            }
                            HStack {
                                Slider(value: $level, in: 0...100, step: 1).frame(width: 220)
                                Text("\(Int(level))%").monospacedDigit().frame(width: 44)
                            }
                            HStack {
                                Text("Fade").font(.system(size: 12.5))
                                TextField("0", value: $fade, format: .number).textFieldStyle(.roundedBorder).frame(width: 52)
                                Text("seconds (0 = instant)").font(.caption).foregroundStyle(Theme.muted)
                            }
                            Text(previewSet).mono(12).foregroundStyle(Theme.muted)
                            Toggle("I confirm this changes hardware", isOn: $confirmSet)
                            Button("Send set") { doSet() }
                                .buttonStyle(.borderedProminent).tint(Theme.accent)
                                .disabled(outputSel.isEmpty || !confirmSet || !lip.isLive)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Press a keypad button").font(.system(size: 13, weight: .bold))
                            Picker("Keypad", selection: $keypadSel) {
                                Text("—").tag("")
                                ForEach(keypadKeys, id: \.self) { Text($0).tag($0) }
                            }
                            Stepper("Button \(button)", value: $button, in: 1...50)
                            Text(previewPress).mono(12).foregroundStyle(Theme.muted)
                            Toggle("I confirm this changes hardware", isOn: $confirmPress)
                            Button("Send press") { doPress() }
                                .buttonStyle(.borderedProminent).tint(Theme.accent)
                                .disabled(keypadSel.isEmpty || !confirmPress || !lip.isLive)
                        }
                    }
                }
                if !log.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Sent this session")
                        ForEach(log.indices, id: \.self) { Text(log[$0]).mono(12) }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ink)).foregroundStyle(.white)
                }
            }
            .padding(26)
        }
    }

    private var outputs: [String] { store.map.areas.flatMap { a in a.outputs.map { "\(a.name)/\($0.name)" } } }
    private var keypadKeys: [String] {
        store.map.areas.flatMap { a in a.keypads.compactMap { $0.lutronID != nil ? "\(a.name)/\($0.name)" : nil } }
    }
    private func outputID(for key: String) -> Int? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return store.map.areas.first { $0.name == parts[0] }?.outputs.first { $0.name == parts[1] }?.lutronID
    }
    private func keypadID(for key: String) -> Int? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return store.map.areas.first { $0.name == parts[0] }?.keypads.first { $0.name == parts[1] }?.lutronID
    }
    private var setCommand: String? {
        guard let id = outputID(for: outputSel) else { return nil }
        let step = CustomMacro.MacroStep(type: .output, outputID: id, level: level, fadeSeconds: fade > 0 ? fade : nil)
        return CustomMacro.lipCommand(for: step)
    }
    private var previewSet: String { setCommand ?? "pick a load" }
    private var previewPress: String { keypadID(for: keypadSel).map { "#DEVICE,\($0),\(button),3" } ?? "pick a keypad" }

    private func doSet() {
        guard let cmd = setCommand else { return }
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
