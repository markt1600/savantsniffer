import SwiftUI
import Combine

/// Shared navigation so the next-step strip can bring you back to the Guide.
@MainActor
final class Nav: ObservableObject {
    @Published var panel: Panel? = .guide
}

struct GuideStep: Identifiable {
    let id: Int
    let title: String
    let what: String
    let doneWhen: String
    let panel: Panel          // the full screen with the same tool, for those who want it
    let done: Bool
    let optional: Bool
    var progress: String = ""
}

/// The ordered plan, computed from the app's real state each time it's drawn.
/// Main-actor because it reads the store and the live client.
@MainActor
enum Guide {
    static func steps(store: DeviceStore, lip: LIPClient) -> [GuideStep] {
        let m = store.map
        let cov = store.overallCoverage()
        let allButtons = m.areas.flatMap { $0.keypads.flatMap { $0.buttons } }
        let macrosLeft = allButtons.filter { $0.kind == "macro" && ($0.effect?.isEmpty ?? true) }.count
        let macrosTotal = allButtons.filter { $0.kind == "macro" }.count
        let savantLeft = allButtons.filter { $0.kind == "integration" && !($0.savantCaptured ?? false) }.count
        let outputs = m.areas.reduce(0) { $0 + $1.outputs.count }
        let hasProcessor = !(m.processor ?? "").isEmpty
        let isLEAP = (m.system ?? "").uppercased().contains("LEAP")

        return [
            GuideStep(id: 1, title: "Find the Lutron processor",
                      what: "Click Run the sweep now. It needs nothing installed and no password. The processor is the host tagged LIP LOGIN (it answers on port 23 with a login prompt), usually with vendor Lutron. Click Use as processor on that row.",
                      doneWhen: "A processor IP is recorded.",
                      panel: .discover, done: hasProcessor, optional: false),
            GuideStep(id: 2, title: "Confirm which Lutron system it is",
                      what: "Click Check ports. Port 23 open means LIP: this app connects to it directly. Port 8081 means LEAP: the newer protocol, which pairs instead of logging in. Click Record this.",
                      doneWhen: "The system type is recorded.",
                      panel: .ports, done: !(m.system ?? "").isEmpty, optional: false),
            isLEAP
            ? GuideStep(id: 3, title: "Pair with the LEAP processor and go live",
                        what: "Port check found LEAP (port 8081): the newer Lutron protocol, which pairs over TLS instead of logging in. Work down the four rows below: set up the Python helper once, pair (press the button on the processor when asked), import the device tree so every room, keypad, button and load appears with the dealer's names, then start monitoring. Everything after this works exactly as with telnet.",
                        doneWhen: "The live session is running.",
                        panel: .monitor, done: lip.isLive || ((m.accessOK ?? false) && (m.source ?? "").contains("LEAP")), optional: false)
            : GuideStep(id: 3, title: "Connect and start monitoring",
                        what: "Leave lutron / integration as the login and click Connect. The pill turns green when logged in. Attempts give up after 10 seconds with a reason. If login is rejected, the real password can be recovered from your own traffic or from Savant's configuration bundle (see Credentials & LEAP).",
                        doneWhen: "A login has succeeded.",
                        panel: .monitor, done: (m.accessOK ?? false) || lip.isLive, optional: false),
            GuideStep(id: 4, title: "Walk the house and label buttons",
                      what: "Press each keypad button once. It appears as a DEVICE row below within a second. Click Label, pick the room, keypad and button name. Do one keypad at a time, top to bottom. Scene buttons (Home Off, Ambient, Movie) are captured properly in the next step.",
                      doneWhen: "Every button is at least identified (no grey dots left on Coverage).",
                      panel: .monitor, done: cov.total > 0 && cov.pending == 0, optional: false,
                      progress: "\(cov.captured + cov.identified) of \(cov.total) buttons seen"),
            GuideStep(id: 5, title: "Capture the scene buttons",
                      what: "In the Capture a button panel: click Arm capture, press the physical scene button, wait until the burst stops, then Name & save. The app records every load the scene touched and the level it ended at.",
                      doneWhen: "Every macro button has its loads recorded.",
                      panel: .monitor, done: macrosTotal > 0 && macrosLeft == 0, optional: false,
                      progress: "\(macrosTotal - macrosLeft) of \(macrosTotal) scenes captured"),
            GuideStep(id: 6, title: "Name your loads",
                      what: "Move a dimmer, or press a single-load button, and click Label on the OUTPUT row. Give the load a name like kitchen island. Named loads are what Control and Custom scenes let you drive directly.",
                      doneWhen: "At least one load is named (more is better).",
                      panel: .monitor, done: outputs > 0, optional: false,
                      progress: "\(outputs) loads named"),
            GuideStep(id: 7, title: "Find the Savant host",
                      what: "Pick the Mac mini from the Apple candidates below. The wired one, often the one that also had a 169.254 address, is usually it. Needed only for the audio and AV steps.",
                      doneWhen: "A Savant host IP is recorded.",
                      panel: .discover, done: !(m.savantHost ?? "").isEmpty, optional: true),
            GuideStep(id: 8, title: "Map audio zones and other Savant-side buttons",
                      what: "Music, Broadcast and volume buttons produce no Lutron output; Savant does the work. Follow the four steps below, then record the zones on each button from the capture panel's Savant-side fields.",
                      doneWhen: "No integration button is left pending.",
                      panel: .capture, done: savantLeft == 0, optional: true,
                      progress: "\(savantLeft) still pending"),
            GuideStep(id: 9, title: "Export the integration report",
                      what: "Click Export report. You get a Markdown file with credentials, the protocol cheat sheet, every button's exact command, every load and scene, plus the JSON map. Keep it private.",
                      doneWhen: "A report has been exported.",
                      panel: .coverage, done: (m.lastExported ?? "").isEmpty == false, optional: false),
            GuideStep(id: 10, title: "Build your own scenes",
                      what: "Clone a captured button's loads, change the levels or add a fade, name it, and save. Run it from the saved list; each run asks for confirmation.",
                      doneWhen: "You have saved at least one scene.",
                      panel: .scenes, done: !(m.customMacros ?? []).isEmpty, optional: true),
        ]
    }

    static func current(_ steps: [GuideStep]) -> GuideStep? {
        steps.first { !$0.done && !$0.optional } ?? steps.first { !$0.done }
    }
}

// MARK: - The page

struct GuideView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient
    @EnvironmentObject var nav: Nav

    /// 0 = follow the current step; -1 = all collapsed; else a step id.
    @State private var expandedID: Int = 0
    @State private var exportNote = ""
    @State private var sceneName = ""
    @State private var sceneSteps: [CustomMacro.MacroStep] = []

    var body: some View {
        let steps = Guide.steps(store: store, lip: lip)
        let currentID = Guide.current(steps)?.id
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Guide",
                           subtitle: "Everything happens on this page, in order. Each step's tool sits under its instructions, and steps tick off from what has actually been captured.") {
                    EmptyView()
                }
                overview(steps, currentID)
                if currentID == nil {
                    Card { HStack { LED(color: Theme.green, glow: true); Text("Everything is captured and exported. Nice work.").font(.system(size: 14, weight: .semibold)) } }
                }
                ForEach(steps) { s in
                    let isCurrent = s.id == currentID
                    let expanded = expandedID == s.id || (expandedID == 0 && isCurrent)
                    StepCard(step: s, isCurrent: isCurrent, expanded: expanded,
                             toggle: { withAnimation(.easeInOut(duration: 0.15)) { expandedID = expanded ? -1 : s.id } },
                             openFull: { nav.panel = s.panel }) {
                        inline(s)
                    }
                }
            }
            .padding(26)
        }
        .onChange(of: currentID) { _ in withAnimation { expandedID = 0 } }
    }

    private func overview(_ steps: [GuideStep], _ currentID: Int?) -> some View {
        HStack(spacing: 6) {
            ForEach(steps) { s in
                Button { withAnimation { expandedID = s.id } } label: {
                    ZStack {
                        Circle().fill(s.done ? Theme.green : (s.id == currentID ? Theme.accent : Theme.greyTint))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(s.id == currentID ? Theme.accent : Theme.border, lineWidth: 1))
                        if s.done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                        else { Text("\(s.id)").font(.system(size: 11, weight: .bold)).foregroundStyle(s.id == currentID ? .white : Theme.muted) }
                    }
                }
                .buttonStyle(.plain)
                .help(s.title)
                if s.id < steps.count { Rectangle().fill(s.done ? Theme.green : Theme.border).frame(width: 14, height: 2) }
            }
            Spacer()
            Text("\(steps.filter { $0.done }.count) of \(steps.count) done").font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func inline(_ s: GuideStep) -> some View {
        switch s.id {
        case 1:
            InlineSweep()
        case 2:
            PortCheckCard()
        case 3:
            ConnectionCard()
        case 4, 5, 6:
            VStack(alignment: .leading, spacing: 12) {
                HStack { ConnectionStatusPill(); Spacer() }
                if !lip.isLive { ConnectionCard() }
                MonitorWorkspace(eventsHeight: 340)
            }
        case 7:
            InlineSavantHost()
        case 8:
            SavantCaptureCard()
        case 9:
            HStack(spacing: 12) {
                Button("Export report…") { exportNote = Exporter.exportViaPanel(store: store, lip: lip) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                if !exportNote.isEmpty { Text(exportNote).font(.caption).foregroundStyle(Theme.muted) }
                if let last = store.map.lastExported, !last.isEmpty { Text("last export \(last)").font(.caption).foregroundStyle(Theme.muted) }
            }
        case 10:
            VStack(alignment: .leading, spacing: 12) {
                SceneBuilder(name: $sceneName, steps: $sceneSteps)
                SavedScenesList { m in sceneName = m.name; sceneSteps = m.steps }
            }
        default:
            EmptyView()
        }
    }
}

struct StepCard<Content: View>: View {
    let step: GuideStep
    let isCurrent: Bool
    let expanded: Bool
    var toggle: () -> Void
    var openFull: () -> Void
    let content: Content

    init(step: GuideStep, isCurrent: Bool, expanded: Bool,
         toggle: @escaping () -> Void, openFull: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.step = step; self.isCurrent = isCurrent; self.expanded = expanded
        self.toggle = toggle; self.openFull = openFull; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle().fill(step.done ? Theme.green : (isCurrent ? Theme.accent : Theme.greyTint)).frame(width: 28, height: 28)
                        if step.done { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                        else { Text("\(step.id)").font(.system(size: 12, weight: .bold)).foregroundStyle(isCurrent ? .white : Theme.muted) }
                    }
                    Text(step.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(step.done ? Theme.muted : Theme.ink)
                    if step.optional { Chip(text: "OPTIONAL", bg: Theme.greyTint, fg: Theme.muted) }
                    if isCurrent { Chip(text: "NEXT", bg: Theme.accentTint, fg: Theme.accent) }
                    if !step.progress.isEmpty { Text(step.progress).font(.system(size: 11.5)).foregroundStyle(Theme.muted).monospacedDigit() }
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(step.what).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Done when: " + step.doneWhen).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Open full screen", action: openFull).buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                }
                content.padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isCurrent ? Theme.accent : Theme.border, lineWidth: isCurrent ? 1.5 : 1))
    }
}

/// One-line "what to do next" shown above every screen except the Guide.
struct NextStepBanner: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient
    @EnvironmentObject var nav: Nav

    var body: some View {
        let steps = Guide.steps(store: store, lip: lip)
        if let s = Guide.current(steps) {
            HStack(spacing: 10) {
                Chip(text: "NEXT STEP", bg: Theme.accentTint, fg: Theme.accent)
                Text("\(s.id). \(s.title)").font(.system(size: 12.5, weight: .semibold))
                if !s.progress.isEmpty { Text("· " + s.progress).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                Spacer()
                Button("Back to the Guide") { nav.panel = .guide }.controlSize(.small).buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(.horizontal, 26).padding(.vertical, 8)
            .background(Theme.panel)
            .overlay(Divider(), alignment: .bottom)
        }
    }
}

// MARK: - Inline tools that exist only on the Guide

/// Run the sweep from inside the Guide and pick the processor.
struct InlineSweep: View {
    @EnvironmentObject var discovery: DiscoveryModel
    @EnvironmentObject var store: DeviceStore
    private var candidates: [DiscoveredHost] { discovery.hosts.filter { $0.isLutronCandidate } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(discovery.scanning ? "Scanning…" : "Run the sweep now") { discovery.runSweep() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(discovery.scanning)
                TextField("subnet", text: $discovery.subnet).textFieldStyle(.roundedBorder).mono(12).frame(width: 150)
                    .onChange(of: discovery.subnet) { _ in discovery.buildCommand() }
                Text("about 15 seconds · nothing to install · no password").font(.caption).foregroundStyle(Theme.muted)
            }
            Text(discovery.scanCommand).mono(11.5)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink)).foregroundStyle(.white)
            ScanProgress()
            if let err = discovery.lastError { Text(err).font(.caption).foregroundStyle(Theme.red) }
            if !discovery.scanning && !discovery.hosts.isEmpty {
                if candidates.isEmpty {
                    Text("No host answered like a Lutron processor. Check the subnet, or the processor may be on a different network segment.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.amberInk)
                } else {
                    ForEach(candidates) { h in
                        HStack(spacing: 10) {
                            LED(color: Theme.purple)
                            Text(h.ip).mono(12.5)
                            Text(h.vendor.isEmpty ? h.classification : h.vendor).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                            if h.lipLogin { Chip(text: "LIP LOGIN", bg: Theme.amberTint, fg: Theme.amberInk) }
                            else if h.lipOpen { Chip(text: "PORT 23", bg: Theme.greyTint, fg: Theme.muted) }
                            if h.leapOpen { Chip(text: "LEAP 8081", bg: Theme.purpleTint, fg: Theme.purple) }
                            Spacer()
                            Button(store.map.processor == h.ip ? "✓ processor" : "Use as processor") { store.map.processor = h.ip; store.save() }
                                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                                .disabled(store.map.processor == h.ip)
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.greyTint))
                    }
                    Text("\(discovery.hosts.count) hosts found in total; the full list is on the Discover screen.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

/// Pick the Savant host from the sweep's Apple candidates.
struct InlineSavantHost: View {
    @EnvironmentObject var discovery: DiscoveryModel
    @EnvironmentObject var store: DeviceStore
    private var candidates: [DiscoveredHost] { discovery.hosts.filter { $0.isSavantCandidate } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if discovery.hosts.isEmpty {
                Text("Run the sweep first (step 1); the candidates appear here.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Button(discovery.scanning ? "Scanning…" : "Run the sweep now") { discovery.runSweep() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(discovery.scanning)
                ScanProgress()
            } else if candidates.isEmpty {
                Text("No Apple or Savant hosts answered. The Mac mini may be asleep or on another segment.").font(.system(size: 12.5)).foregroundStyle(Theme.amberInk)
            } else {
                ForEach(candidates) { h in
                    HStack(spacing: 10) {
                        LED(color: Theme.blue)
                        Text(h.ip).mono(12.5)
                        Text(h.vendor.isEmpty ? h.classification : h.vendor).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Spacer()
                        Button(store.map.savantHost == h.ip ? "✓ Savant host" : "Use as Savant host") { store.map.savantHost = h.ip; store.save() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                            .disabled(store.map.savantHost == h.ip)
                    }
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.greyTint))
                }
            }
        }
    }
}

/// Determinate progress for the sweep; shared by the Guide and Discover.
struct ScanProgress: View {
    @EnvironmentObject var discovery: DiscoveryModel
    var body: some View {
        if discovery.scanning {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: discovery.progressFraction).tint(Theme.accent)
                HStack {
                    Text(discovery.progress).font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                    Spacer()
                    Text("\(discovery.candidatesSoFar) answering so far").font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                }
            }
        }
    }
}
