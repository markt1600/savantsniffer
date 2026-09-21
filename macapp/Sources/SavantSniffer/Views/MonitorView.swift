import SwiftUI

struct MonitorView: View {
    @EnvironmentObject var lip: LIPClient
    @EnvironmentObject var store: DeviceStore

    @State private var host = ""
    @State private var user = "lutron"
    @State private var pass = "integration"
    @State private var labelTarget: MonitorEvent?
    @State private var showMacroSave = false
    @State private var macroTick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monitor & label").font(.largeTitle.bold())
            Text("Read-only: enables event reporting and streams keypad/load events. Walk the house, press a button, then label the event that appears.")
                .foregroundStyle(.secondary).font(.callout)

            connectionBar
            statusBar
            macroBar
            Divider()
            eventList
        }
        .padding(24)
        .onAppear {
            if host.isEmpty { host = store.map.processor ?? "" }
            if let saved = Keychain.get(account: user) { pass = saved }
        }
        .onReceive(timer) { _ in macroTick += 1 } // refresh macro settle state
        .onChange(of: lip.state) { st in
            if st == .monitoring { store.map.accessOK = true; store.save() }
        }
        .sheet(item: $labelTarget) { ev in LabelSheet(event: ev) }
        .sheet(isPresented: $showMacroSave) { MacroSaveSheet() }
    }

    private var connectionBar: some View {
        HStack {
            TextField("processor IP", text: $host).frame(width: 150)
            TextField("user", text: $user).frame(width: 90)
            SecureField("password", text: $pass).frame(width: 120)
            Button("Save pw") { Keychain.set(pass, account: user) }
            if lip.state == .monitoring || lip.state == .connecting || lip.state == .authenticating {
                Button("Disconnect") { lip.disconnect() }
            } else {
                Button("Connect") { lip.connect(host: host, user: user, pass: pass) }
                    .disabled(host.isEmpty)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 10, height: 10)
            Text(stateText).font(.callout)
            if !lip.systemName.isEmpty { Text("· \(lip.systemName) \(lip.prompt)").foregroundStyle(.secondary) }
            Spacer()
        }
    }

    private var macroBar: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading) {
                    Text("Capture a macro / integration button").font(.callout.bold())
                    Text("Arm, press the physical button, watch the burst, then save it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if lip.recorder.active {
                    let _ = macroTick
                    Text("\(lip.recorder.steps.count) events · \(Set(lip.recorder.steps.map{$0.id}).count) loads · guess: \(lip.recorder.classify())")
                        .font(.caption).monospacedDigit()
                    Button("Save…") { showMacroSave = true }
                } else {
                    Button("Arm capture") { lip.recorder.begin() }
                        .disabled(lip.state != .monitoring)
                }
            }.padding(6)
        }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("time").frame(width: 90, alignment: .leading)
                Text("kind").frame(width: 60, alignment: .leading)
                Text("id").frame(width: 40, alignment: .leading)
                Text("detail").frame(width: 130, alignment: .leading)
                Text("raw")
                Spacer()
            }.font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lip.events.reversed()) { ev in
                        HStack {
                            Text(ev.timeString).font(.caption.monospaced()).frame(width: 90, alignment: .leading)
                            Text(ev.kind.rawValue).font(.caption).frame(width: 60, alignment: .leading)
                                .foregroundStyle(ev.kind == .device ? .blue : .green)
                            Text(ev.integrationID.map(String.init) ?? "").font(.caption.monospaced()).frame(width: 40, alignment: .leading)
                            Text(ev.detail).font(.caption).frame(width: 130, alignment: .leading)
                            Text(ev.raw).font(.caption.monospaced())
                            Spacer()
                            Button("Label") { labelTarget = ev }.font(.caption)
                        }
                        .padding(.vertical, 2).padding(.horizontal, 4)
                        .background((lip.events.count % 2 == 0) ? Color.clear : Color.gray.opacity(0.04))
                    }
                }
            }
        }
    }

    private var stateColor: Color {
        switch lip.state {
        case .monitoring: return .green
        case .connecting, .authenticating: return .yellow
        case .failed: return .red
        default: return .gray
        }
    }
    private var stateText: String {
        switch lip.state {
        case .idle: return "idle"
        case .connecting: return "connecting…"
        case .authenticating: return "authenticating…"
        case .monitoring: return "monitoring"
        case .closed: return "closed"
        case .failed(let e): return "failed: \(e)"
        }
    }
}
