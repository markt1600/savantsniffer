import SwiftUI

struct MonitorView: View {
    @EnvironmentObject var lip: LIPClient
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var discovery: DiscoveryModel

    @State private var host = ""
    @State private var user = "lutron"
    @State private var pass = "integration"
    @State private var labelTarget: MonitorEvent?
    @State private var showMacroSave = false
    @State private var paused = false
    @State private var frozen: [MonitorEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Monitor & label",
                       subtitle: "Read-only. Walk the house, press a button, then label the event that appears.") {
                connectionPill
            }
            connectionCard
            if let notice = leapNotice { notice }
            if case .failed(let why) = lip.state {
                Label(why, systemImage: "xmark.octagon").font(.system(size: 12.5)).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 16) {
                eventsCard
                VStack(spacing: 14) {
                    CapturePanel(recorder: lip.recorder, live: lip.isLive) { showMacroSave = true }
                    recentCard
                    Spacer(minLength: 0)
                }
                .frame(width: 330)
            }
        }
        .padding(26)
        .onAppear {
            if host.isEmpty { host = store.map.processor ?? "" }
            user = UserDefaults.standard.string(forKey: "lipUser") ?? "lutron"
            if let saved = Keychain.get(account: user) { pass = saved }
        }
        .onChange(of: lip.state) { st in
            if st == .monitoring {
                store.map.accessOK = true
                if (store.map.processor ?? "").isEmpty { store.map.processor = host }
                if lip.systemName.hasPrefix("HomeWorks") || lip.systemName.hasPrefix("RadioRA") { store.map.system = "LIP · " + lip.systemName }
                store.save()
            }
        }
        .sheet(item: $labelTarget) { ev in
            LabelSheet(event: ev).environmentObject(store)
        }
        .sheet(isPresented: $showMacroSave) {
            MacroSaveSheet(recorder: lip.recorder).environmentObject(store).environmentObject(lip)
        }
    }

    /// If the recorded system or the sweep says this host speaks LEAP, not LIP, say so.
    private var leapNotice: AnyView? {
        let sys = (store.map.system ?? "").uppercased()
        let sweep = discovery.hosts.first { $0.ip == host }
        let leapOnly = (sweep.map { $0.leapOpen && !$0.lipOpen } ?? false)
        guard sys.contains("LEAP") || leapOnly else { return nil }
        return AnyView(
            Card(padding: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This looks like a LEAP-generation Lutron device, not a telnet (LIP) one.").font(.system(size: 13, weight: .semibold))
                        Text((leapOnly ? "During the sweep \(host) answered on port 8081 (LEAP) but not on port 23. " : "The recorded system type is LEAP. ")
                             + "Telnet monitoring won't work here. Use the LEAP pairing steps on Credentials & LEAP, or, on RA2 Select / HomeWorks QSX, check whether telnet integration can be enabled on the processor.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        )
    }

    // MARK: header pill
    private var connectionPill: some View {
        HStack(spacing: 10) {
            LED(color: stateColor, glow: lip.isLive, size: 9)
            Text(stateText).font(.system(size: 12.5, weight: .semibold))
            if lip.isLive { Text("\(lip.systemName) · \(lip.prompt)").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            else if case .failed = lip.state { Text("see below").font(.system(size: 12)).foregroundStyle(Theme.red) }
            else if lip.state == .connecting { Text("gives up after 10 s").font(.system(size: 12)).foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }

    private var connectionCard: some View {
        Card(padding: 16) {
            HStack(alignment: .bottom, spacing: 12) {
                field("Processor", $host, width: 160, mono: true)
                field("User", $user, width: 110)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    SecureField("", text: $pass).textFieldStyle(.roundedBorder).frame(width: 150)
                }
                Spacer()
                Button("Save to Keychain") {
                    Keychain.set(pass, account: user)
                    UserDefaults.standard.set(user, forKey: "lipUser")
                }
                if lip.state == .monitoring || lip.state == .connecting || lip.state == .authenticating {
                    Button("Disconnect") { lip.disconnect() }
                } else {
                    Button("Connect") { lip.connect(host: host, user: user, pass: pass) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(host.isEmpty)
                }
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, width: CGFloat, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            if mono { TextField("", text: text).textFieldStyle(.roundedBorder).mono(13).frame(width: width) }
            else { TextField("", text: text).textFieldStyle(.roundedBorder).frame(width: width) }
        }
    }

    // MARK: events
    private var visibleEvents: [MonitorEvent] { (paused ? frozen : lip.events).reversed() }

    private var eventsCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Live events").font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("\(lip.events.count) this session").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button(paused ? "Resume" : "Pause") {
                        if !paused { frozen = lip.events }
                        paused.toggle()
                    }.controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.greyTint)
                Divider()
                HStack(spacing: 12) {
                    SectionLabel("time").frame(width: 92, alignment: .leading)
                    SectionLabel("kind").frame(width: 74, alignment: .leading)
                    SectionLabel("id").frame(width: 36, alignment: .leading)
                    SectionLabel("detail").frame(width: 120, alignment: .leading)
                    SectionLabel("raw")
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleEvents) { ev in
                            EventRow(ev: ev) { labelTarget = ev }
                        }
                        if lip.events.isEmpty {
                            Text(lip.isLive ? "Waiting for events. Press a keypad button in the house." : "Connect to start streaming events.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(24)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var recentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recently labelled").font(.system(size: 13, weight: .bold))
                if store.recentLabels.isEmpty {
                    Text("Nothing yet. Click Label on an event.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(store.recentLabels, id: \.self) { entry in
                    let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
                    HStack(alignment: .top, spacing: 10) {
                        LED(color: Theme.green).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(parts.first ?? entry).font(.system(size: 12.5, weight: .semibold))
                            if parts.count > 1 { Text(parts[1]).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                        }
                    }
                }
            }
        }
    }

    private var stateColor: Color {
        switch lip.state {
        case .monitoring: return Theme.green
        case .connecting, .authenticating: return Theme.amber
        case .failed: return Theme.red
        default: return Theme.grey
        }
    }
    private var stateText: String {
        switch lip.state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .authenticating: return "Logging in…"
        case .monitoring: return "Connected"
        case .closed: return "Disconnected"
        case .failed: return "Failed"
        }
    }
}

struct EventRow: View {
    let ev: MonitorEvent
    var onLabel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(ev.timeString).mono(12).foregroundStyle(Theme.muted).frame(width: 92, alignment: .leading)
            Chip.kind(ev.kind.rawValue).frame(width: 74, alignment: .leading)
            Text(ev.integrationID.map { String($0) } ?? "").mono(12.5).frame(width: 36, alignment: .leading)
            Text(ev.detail).font(.system(size: 12.5)).foregroundStyle(Theme.ink.opacity(0.8)).frame(width: 120, alignment: .leading)
            Text(ev.raw).mono(12.5)
            Spacer()
            Button("Label", action: onLabel).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(ev.capturing ? Theme.greenTint : Color.clear)
        .overlay(Divider(), alignment: .bottom)
    }
}

struct CapturePanel: View {
    @ObservedObject var recorder: MacroRecorder
    var live: Bool
    var onSave: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Capture a button").font(.system(size: 13, weight: .bold))
                    Spacer()
                    if recorder.active { Chip(text: "CAPTURING", bg: Theme.amberTint, fg: Theme.amberInk) }
                    else { Chip(text: "IDLE", bg: Theme.greyTint, fg: Theme.muted) }
                }
                Text("Arm, press the physical button, let the burst settle, then name it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if recorder.active {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(guessText).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(recorder.steps.count) events · \(recorder.loadsAffected) loads").font(.system(size: 11.5)).foregroundStyle(Theme.muted).monospacedDigit()
                        }
                        ForEach(recorder.effect(), id: \.id) { e in
                            HStack { Text("output \(e.id)").mono(12); Spacer(); Text("→ \(Int(e.level))%").mono(12).foregroundStyle(Theme.muted) }
                        }
                        HStack(spacing: 8) {
                            LED(color: recorder.triggerDevice != nil ? Theme.amber : Theme.grey)
                            Text(recorder.triggerDevice != nil
                                 ? "trigger: keypad \(recorder.triggerDevice!), button \(recorder.triggerButton ?? 0)"
                                 : "no keypad press seen yet").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.greyTint))
                    HStack(spacing: 8) {
                        Button("Discard") { recorder.finish() }
                        Button("Name & save…", action: onSave)
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(recorder.triggerDevice == nil && recorder.steps.isEmpty)
                    }
                } else {
                    Button("Arm capture") { recorder.begin() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(!live)
                    if !live { Text("Connect first.").font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                }
            }
        }
    }

    private var guessText: String {
        switch recorder.classify() {
        case "macro": return "Likely a macro / scene"
        case "output": return "Likely a single load"
        default: return "No Lutron output yet (integration?)"
        }
    }
}
