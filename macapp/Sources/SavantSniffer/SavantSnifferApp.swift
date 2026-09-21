import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SavantSnifferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = DeviceStore()
    @StateObject private var lip = LIPClient()
    @StateObject private var discovery = DiscoveryModel()
    @StateObject private var portcheck = PortCheckModel()

    var body: some Scene {
        WindowGroup("SavantSniffer") {
            ContentView()
                .environmentObject(store)
                .environmentObject(lip)
                .environmentObject(discovery)
                .environmentObject(portcheck)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.titleBar)
    }
}

enum Panel: String, CaseIterable, Identifiable {
    case coverage, discover, ports, capture, monitor, map, control, scenes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .coverage: return "Coverage"
        case .discover: return "Discover"
        case .ports: return "Port check"
        case .capture: return "Credentials & LEAP"
        case .monitor: return "Monitor & label"
        case .map: return "Device map"
        case .control: return "Control"
        case .scenes: return "Custom scenes"
        }
    }
    var icon: String {
        switch self {
        case .coverage: return "checkmark.seal"
        case .discover: return "dot.radiowaves.left.and.right"
        case .ports: return "network"
        case .capture: return "key"
        case .monitor: return "waveform.path.ecg"
        case .map: return "list.bullet.rectangle"
        case .control: return "slider.horizontal.3"
        case .scenes: return "wand.and.stars"
        }
    }
}

struct ContentView: View {
    @State private var selection: Panel? = .coverage
    @EnvironmentObject var lip: LIPClient
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accent)
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: "waveform.path.ecg").foregroundStyle(.white).font(.system(size: 13, weight: .bold)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SavantSniffer").font(.system(size: 14, weight: .bold))
                        Text("observe-first").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)

                List(selection: $selection) {
                    Section("Setup") { row(.discover); row(.ports); row(.capture) }
                    Section("Capture") { row(.coverage); row(.monitor); row(.map) }
                    Section("Control") { row(.control); row(.scenes) }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                statusCard.padding(12)
            }
            .background(Theme.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 300)
        } detail: {
            detail(for: selection ?? .coverage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ground)
        }
    }

    private func row(_ p: Panel) -> some View {
        Label(p.title, systemImage: p.icon).tag(p)
    }

    @ViewBuilder
    private func detail(for p: Panel) -> some View {
        switch p {
        case .coverage: CoverageView()
        case .discover: DiscoverView()
        case .ports: PortCheckView()
        case .capture: CaptureGuideView()
        case .monitor: MonitorView()
        case .map: MapView()
        case .control: ControlView()
        case .scenes: ScenesView()
        }
    }

    private var statusCard: some View {
        HStack(spacing: 8) {
            LED(color: lip.isLive ? Theme.green : (lip.state == .connecting || lip.state == .authenticating ? Theme.amber : Theme.grey), glow: lip.isLive, size: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(lip.isLive ? "Monitoring" : "Not connected").font(.system(size: 12, weight: .semibold))
                Text(lip.isLive ? "\(store.map.processor ?? "") · \(lip.prompt)" : (store.map.processor ?? "no processor yet"))
                    .mono(11).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}
