import SwiftUI
import Combine

/// Shared navigation so the Guide (and the next-step banner) can move you to a screen.
@MainActor
final class Nav: ObservableObject {
    @Published var panel: Panel? = .guide
}

struct GuideStep: Identifiable {
    let id: Int
    let title: String
    let what: String
    let doneWhen: String
    let panel: Panel
    let go: String
    let done: Bool
    let optional: Bool
    var progress: String = ""
    var inlineSweep = false      // step 1 can run the network sweep right here
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

        return [
            GuideStep(id: 1, title: "Find the Lutron processor",
                      what: "On Discover, click Run built-in sweep. It needs nothing installed. The processor is the host tagged LIP login (it answers on port 23 with a login prompt), usually with vendor Lutron. Click Use as processor on that row.",
                      doneWhen: "A processor IP is recorded.",
                      panel: .discover, go: "Open Discover", done: hasProcessor, optional: false, inlineSweep: true),
            GuideStep(id: 2, title: "Confirm which Lutron system it is",
                      what: "Port check the processor. Port 23 open means LIP: this app connects to it directly. Port 8081 means LEAP: pair with the Python tool described on Credentials & LEAP instead. Click Record this.",
                      doneWhen: "The system type is recorded.",
                      panel: .ports, go: "Open Port check", done: !(m.system ?? "").isEmpty, optional: false),
            (m.system ?? "").uppercased().contains("LEAP")
            ? GuideStep(id: 3, title: "Pair with the LEAP processor",
                        what: "Port check found LEAP (port 8081), the newer Lutron protocol. It uses TLS and pairing instead of a telnet login, so the Monitor screen doesn't apply. Follow the LEAP section on Credentials & LEAP: install pylutron-caseta, run pair, press the button on the processor, then dump the device tree. If your processor is a RA2 Select or HomeWorks QSX, telnet (LIP) can sometimes be enabled on it instead, which would let the rest of this app work as designed.",
                        doneWhen: "Pairing succeeded (certificate files written).",
                        panel: .capture, go: "Open Credentials & LEAP", done: (m.accessOK ?? false) || lip.isLive, optional: false)
            : GuideStep(id: 3, title: "Connect and start monitoring",
                        what: "On Monitor, leave lutron / integration as the login and click Connect. The pill turns green when logged in. Connection attempts give up after 10 seconds with a reason. If login is rejected, Credentials & LEAP explains how to recover the real password from your own traffic or from the Savant configuration bundle.",
                        doneWhen: "A login has succeeded.",
                        panel: .monitor, go: "Open Monitor", done: (m.accessOK ?? false) || lip.isLive, optional: false),
            GuideStep(id: 4, title: "Walk the house and label buttons",
                      what: "Press each keypad button once. It appears as a DEVICE row within a second. Click Label, pick the room, keypad and button name. Do one keypad at a time, top to bottom, and it goes quickly. Buttons that light more than one load can be captured properly in the next step.",
                      doneWhen: "Every button is at least identified (no grey dots left on Coverage).",
                      panel: .monitor, go: "Open Monitor", done: cov.total > 0 && cov.pending == 0, optional: false,
                      progress: "\(cov.captured + cov.identified) of \(cov.total) buttons seen"),
            GuideStep(id: 5, title: "Capture the scene buttons",
                      what: "For scene buttons like Home Off, Ambient, Relaxed or Movie: click Arm capture, press the physical button, wait until the burst stops, then Name & save. The app records every load the scene touched and the level it ended at.",
                      doneWhen: "Every macro button has its loads recorded.",
                      panel: .monitor, go: "Open Monitor", done: macrosTotal > 0 && macrosLeft == 0, optional: false,
                      progress: "\(macrosTotal - macrosLeft) of \(macrosTotal) scenes captured"),
            GuideStep(id: 6, title: "Name your loads",
                      what: "Move a dimmer, or press a single-load button, and click Label on the OUTPUT row. Give the load a name like kitchen island. Named loads are what Control and Custom scenes let you drive directly.",
                      doneWhen: "At least one load is named (more is better).",
                      panel: .monitor, go: "Open Monitor", done: outputs > 0, optional: false,
                      progress: "\(outputs) loads named"),
            GuideStep(id: 7, title: "Find the Savant host",
                      what: "On Discover, Apple hosts are candidates. The wired one, often the one that also shows a 169.254 address, is usually the Mac mini. Click Use as Savant host. Needed only for the audio and AV steps.",
                      doneWhen: "A Savant host IP is recorded.",
                      panel: .discover, go: "Open Discover", done: !(m.savantHost ?? "").isEmpty, optional: true),
            GuideStep(id: 8, title: "Map audio zones and other Savant-side buttons",
                      what: "Music, Broadcast and volume buttons produce no Lutron output; Savant does the work. Follow the Savant capture steps on Credentials & LEAP, run correlate, then record the zones on each button from the capture sheet.",
                      doneWhen: "No integration button is left pending.",
                      panel: .capture, go: "Open Credentials & LEAP", done: savantLeft == 0, optional: true,
                      progress: "\(savantLeft) still pending"),
            GuideStep(id: 9, title: "Export the integration report",
                      what: "On Coverage, click Export report. You get a Markdown file with credentials, the protocol cheat sheet, every button's exact command, every load and scene, plus the JSON map. Keep it private.",
                      doneWhen: "A report has been exported.",
                      panel: .coverage, go: "Open Coverage", done: (m.lastExported ?? "").isEmpty == false, optional: false),
            GuideStep(id: 10, title: "Build your own scenes",
                      what: "On Custom scenes, clone a captured button's loads, change the levels or add a fade, and save. Run it from the same screen; each run asks for confirmation.",
                      doneWhen: "You have saved at least one scene.",
                      panel: .scenes, go: "Open Custom scenes", done: !(m.customMacros ?? []).isEmpty, optional: true),
        ]
    }

    static func current(_ steps: [GuideStep]) -> GuideStep? {
        steps.first { !$0.done && !$0.optional } ?? steps.first { !$0.done }
    }
}

struct GuideView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var lip: LIPClient
    @EnvironmentObject var nav: Nav

    var body: some View {
        let steps = Guide.steps(store: store, lip: lip)
        let current = Guide.current(steps)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Guide",
                           subtitle: "Do these in order. The app checks each one off from what it has actually captured, so this list is always current.") {
                    EmptyView()
                }
                if current == nil {
                    Card { HStack { LED(color: Theme.green, glow: true); Text("Everything is captured and exported. Nice work.").font(.system(size: 14, weight: .semibold)) } }
                }
                ForEach(steps) { s in
                    StepCard(step: s, isCurrent: s.id == current?.id) { nav.panel = s.panel }
                }
            }
            .padding(26)
        }
    }
}

struct StepCard: View {
    @EnvironmentObject var discovery: DiscoveryModel
    @EnvironmentObject var store: DeviceStore
    let step: GuideStep
    let isCurrent: Bool
    var go: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(step.done ? Theme.green : (isCurrent ? Theme.accent : Theme.greyTint)).frame(width: 28, height: 28)
                if step.done { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(step.id)").font(.system(size: 12, weight: .bold)).foregroundStyle(isCurrent ? .white : Theme.muted) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(step.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(step.done ? Theme.muted : Theme.ink)
                    if step.optional { Chip(text: "OPTIONAL", bg: Theme.greyTint, fg: Theme.muted) }
                    if isCurrent { Chip(text: "NEXT", bg: Theme.accentTint, fg: Theme.accent) }
                    if !step.progress.isEmpty { Text(step.progress).font(.system(size: 11.5)).foregroundStyle(Theme.muted).monospacedDigit() }
                    Spacer()
                }
                if isCurrent || !step.done {
                    Text(step.what).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    Text("Done when: " + step.doneWhen).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if step.inlineSweep && !step.done {
                    InlineSweep()
                }
                if !step.done {
                    Button(step.go, action: go)
                        .buttonStyle(.borderedProminent)
                        .tint(isCurrent && !step.inlineSweep ? Theme.accent : Theme.muted)
                        .controlSize(.small)
                }
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
                Button("Show me") { nav.panel = .guide }.controlSize(.small)
                if nav.panel != s.panel { Button(s.go) { nav.panel = s.panel }.controlSize(.small).buttonStyle(.borderedProminent).tint(Theme.accent) }
            }
            .padding(.horizontal, 26).padding(.vertical, 8)
            .background(Theme.panel)
            .overlay(Divider(), alignment: .bottom)
        }
    }
}


/// Run the sweep from inside the Guide and watch it work.
struct InlineSweep: View {
    @EnvironmentObject var discovery: DiscoveryModel
    @EnvironmentObject var store: DeviceStore

    private var candidates: [DiscoveredHost] { discovery.hosts.filter { $0.isLutronCandidate } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(discovery.scanCommand).mono(11.5)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink)).foregroundStyle(.white)
            HStack(spacing: 10) {
                Button(discovery.scanning ? "Scanning…" : "Run the sweep now") { discovery.runSweep() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(discovery.scanning)
                Text("about 15 seconds · nothing to install · no password").font(.caption).foregroundStyle(Theme.muted)
            }
            ScanProgress()
            if !discovery.scanning && !discovery.hosts.isEmpty {
                if candidates.isEmpty {
                    Text("No host answered like a Lutron processor. Check the subnet, or the processor may be on a different network segment.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.amberInk)
                } else {
                    ForEach(candidates) { h in
                        HStack(spacing: 10) {
                            LED(color: Theme.purple)
                            Text(h.ip).mono(12.5)
                            Text(h.vendor.isEmpty ? h.classification : h.vendor).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            if h.lipLogin { Chip(text: "LIP LOGIN", bg: Theme.amberTint, fg: Theme.amberInk) }
                            if h.leapOpen { Chip(text: "LEAP", bg: Theme.purpleTint, fg: Theme.purple) }
                            Spacer()
                            Button("Use as processor") { store.map.processor = h.ip; store.save() }
                                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.greyTint))
                    }
                }
            }
        }
        .padding(.top, 4)
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
