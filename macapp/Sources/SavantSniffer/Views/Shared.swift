import SwiftUI
import AppKit

// Reusable working pieces, used by both the Guide (inline) and the full screens.

/// A command with a copy button.
struct CommandLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).mono(12).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink)).foregroundStyle(.white)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .controlSize(.small)
            .accessibilityLabel("Copy command")
        }
    }
}

// MARK: - Connection

struct ConnectionStatusPill: View {
    @EnvironmentObject var lip: LIPClient
    var body: some View {
        HStack(spacing: 10) {
            LED(color: color, glow: lip.isLive, size: 9)
            Text(text).font(.system(size: 12.5, weight: .semibold))
            if lip.isLive { Text("\(lip.systemName) · \(lip.prompt)").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            else if case .failed = lip.state { Text("see below").font(.system(size: 12)).foregroundStyle(Theme.red) }
            else if lip.state == .connecting { Text("gives up after 10 s").font(.system(size: 12)).foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }
    private var color: Color {
        switch lip.state {
        case .monitoring: return Theme.green
        case .connecting, .authenticating: return Theme.amber
        case .failed: return Theme.red
        default: return Theme.grey
        }
    }
    private var text: String {
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

/// Host / user / password + Connect, with LEAP notice and failure reason.
struct ConnectionCard: View {
    @EnvironmentObject var lip: LIPClient
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var discovery: DiscoveryModel
    @State private var host = ""
    @State private var user = "lutron"
    @State private var pass = "integration"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            if let notice = leapNotice { notice }
            if case .failed(let why) = lip.state {
                Label(why, systemImage: "xmark.octagon").font(.system(size: 12.5)).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if host.isEmpty { host = store.map.processor ?? "" }
            user = UserDefaults.standard.string(forKey: "lipUser") ?? "lutron"
            if let saved = Keychain.get(account: user) { pass = saved }
        }
        .onChange(of: store.map.processor) { p in if host.isEmpty, let p = p { host = p } }
        .onChange(of: lip.state) { st in
            if st == .monitoring {
                store.map.accessOK = true
                if (store.map.processor ?? "").isEmpty { store.map.processor = host }
                if lip.systemName.hasPrefix("HomeWorks") || lip.systemName.hasPrefix("RadioRA") { store.map.system = "LIP · " + lip.systemName }
                store.save()
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
                             + "Telnet monitoring won't work here. Use the LEAP pairing steps, or, on RA2 Select / HomeWorks QSX, check whether telnet integration can be enabled on the processor.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        )
    }
}

// MARK: - Live events

struct EventsPanel: View {
    @EnvironmentObject var lip: LIPClient
    var height: CGFloat? = nil
    var onLabel: (MonitorEvent) -> Void
    @State private var paused = false
    @State private var frozen: [MonitorEvent] = []

    private var visible: [MonitorEvent] { (paused ? frozen : lip.events).reversed() }

    var body: some View {
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
                        ForEach(visible) { ev in EventRow(ev: ev) { onLabel(ev) } }
                        if lip.events.isEmpty {
                            Text(lip.isLive ? "Waiting for events. Press a keypad button in the house." : "Connect to start streaming events.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(24)
                        }
                    }
                }
                .frame(height: height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

struct RecentLabelsCard: View {
    @EnvironmentObject var store: DeviceStore
    var body: some View {
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
}

/// Events + capture rail + recent labels, with the two sheets. Used by Monitor and the Guide.
struct MonitorWorkspace: View {
    @EnvironmentObject var lip: LIPClient
    @EnvironmentObject var store: DeviceStore
    var eventsHeight: CGFloat? = nil
    @State private var labelTarget: MonitorEvent?
    @State private var showMacroSave = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            EventsPanel(height: eventsHeight) { labelTarget = $0 }
            VStack(spacing: 14) {
                CapturePanel(recorder: lip.recorder, live: lip.isLive) { showMacroSave = true }
                RecentLabelsCard()
                Spacer(minLength: 0)
            }
            .frame(width: 330)
        }
        .sheet(item: $labelTarget) { ev in LabelSheet(event: ev).environmentObject(store) }
        .sheet(isPresented: $showMacroSave) {
            MacroSaveSheet(recorder: lip.recorder).environmentObject(store).environmentObject(lip)
        }
    }
}

// MARK: - Port check

struct PortCheckCard: View {
    @EnvironmentObject var portcheck: PortCheckModel
    @EnvironmentObject var store: DeviceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Processor IP").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        TextField("192.168.1.50", text: $portcheck.host).textFieldStyle(.roundedBorder).mono(13).frame(width: 180)
                    }
                    if let p = store.map.processor, !p.isEmpty, p != portcheck.host {
                        Button("Use \(p)") { portcheck.host = p }
                    }
                    Button(portcheck.checking ? "Checking…" : "Check ports") { portcheck.check() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(portcheck.checking || portcheck.host.isEmpty)
                }
            }
            if !portcheck.results.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(portcheck.results) { r in
                            HStack(spacing: 12) {
                                BoolDot(ok: r.open)
                                Text("\(r.port)").mono(13).frame(width: 50, alignment: .leading)
                                Text(r.open ? "OPEN" : "closed").font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(r.open ? Theme.greenInk : Theme.muted).frame(width: 60, alignment: .leading)
                                Text(PORT_LABELS[r.port] ?? "").font(.caption).foregroundStyle(Theme.muted)
                                Spacer()
                            }
                        }
                    }
                }
            }
            if !portcheck.likelySystem.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Likely system: \(portcheck.likelySystem)").font(.system(size: 15, weight: .bold))
                        Text(portcheck.reasoning).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        Button(store.map.system == portcheck.likelySystem ? "✓ Recorded" : "Record this") {
                            store.map.system = portcheck.likelySystem
                            if (store.map.processor ?? "").isEmpty { store.map.processor = portcheck.host }
                            store.save()
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(store.map.system == portcheck.likelySystem)
                    }
                }
            }
        }
        .onAppear { if portcheck.host.isEmpty { portcheck.host = store.map.processor ?? "" } }
        .onChange(of: store.map.processor) { p in if portcheck.host.isEmpty, let p = p { portcheck.host = p } }
    }
}

// MARK: - Savant-side capture commands

struct SavantCaptureCard: View {
    @EnvironmentObject var store: DeviceStore
    @State private var iface = "en0"
    private var savant: String { store.map.savantHost ?? "<savant-ip>" }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Savant capture: audio zones, music, AV").font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("interface").font(.caption).foregroundStyle(Theme.muted)
                    TextField("en0", text: $iface).textFieldStyle(.roundedBorder).frame(width: 70)
                }
                Text("Lutron only reports the keypad press. Savant hears that same press and sends its own commands to the audio hardware. Capture the Savant host's traffic while you press those buttons, then correlate by time.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Text("1. In Terminal, capture, filtered to the Savant host:").font(.system(size: 12.5))
                CommandLine(text: "sudo tcpdump -i \(iface) -s 0 -w ~/savant.pcap 'host \(savant)'")
                Text("2. Keep monitoring running here and press the buttons (Music, Broadcast, office lights). Every press is timestamped.").font(.system(size: 12.5))
                Text("3. Export the packets as text and correlate:").font(.system(size: 12.5))
                CommandLine(text: "tshark -r ~/savant.pcap -Y 'ip.src==\(savant)' -T fields -E separator=/t -e frame.time_epoch -e ip.dst -e tcp.dstport -e udp.dstport -e tcp.payload -e udp.payload > ~/savant.txt")
                CommandLine(text: "lutron correlate --savant ~/savant.txt --monitor-log <latest monitor log>")
                Text("4. Note which zones came on for each press, then record them on the button: arm capture, press it, Name & save, and fill the audio zone fields. Plain-TCP commands can be replayed as Savant steps in a custom scene.")
                    .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LEAPCommandsCard: View {
    @EnvironmentObject var store: DeviceStore
    private var proc: String { store.map.processor ?? "<processor-ip>" }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("LEAP pairing (QSX / RadioRA 3 / RA2 Select / Caseta)").font(.system(size: 13, weight: .bold))
                Text("LEAP is TLS, so there is no password to recover; you pair instead, using the bundled Python tool. Run these in Terminal from the repo folder.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                CommandLine(text: "pip install pylutron-caseta")
                CommandLine(text: "python3 -m savantsniffer.leap pair \(proc)")
                CommandLine(text: "python3 -m savantsniffer.leap dump \(proc)")
                Text("Press the pairing button on the processor when prompted. The dump lists every area, device, button and zone.").font(.caption).foregroundStyle(Theme.muted)
                Button("Mark pairing done") { store.map.accessOK = true; store.save() }.controlSize(.small)
            }
        }
    }
}
