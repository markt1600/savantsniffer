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
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}

enum Panel: String, CaseIterable, Identifiable {
    case coverage = "Coverage"
    case discover = "1 · Discover"
    case ports = "2 · Port check"
    case monitor = "3 · Monitor & label"
    case scenes = "Custom scenes"
    case control = "Control"
    case map = "Device map"
    case capture = "Credentials & LEAP"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .coverage: return "checkmark.seal"
        case .discover: return "dot.radiowaves.left.and.right"
        case .ports: return "network"
        case .monitor: return "waveform.path.ecg"
        case .scenes: return "wand.and.stars"
        case .control: return "slider.horizontal.3"
        case .map: return "list.bullet.rectangle"
        case .capture: return "key"
        }
    }
}

struct ContentView: View {
    @State private var selection: Panel = .coverage
    var body: some View {
        NavigationSplitView {
            List(Panel.allCases, selection: $selection) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch selection {
            case .coverage: CoverageView()
            case .discover: DiscoverView()
            case .ports: PortCheckView()
            case .monitor: MonitorView()
            case .scenes: ScenesView()
            case .control: ControlView()
            case .map: MapView()
            case .capture: CaptureGuideView()
            }
        }
    }
}

// Shared small UI helpers
struct StatusDot: View {
    let status: DeviceMap.CaptureStatus
    var body: some View {
        Circle().fill(color).frame(width: 11, height: 11)
            .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
    }
    var color: Color {
        switch status {
        case .captured: return .green
        case .identified: return .yellow
        case .pending: return Color.gray.opacity(0.4)
        }
    }
}

struct BoolDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.gray.opacity(0.4))
            .frame(width: 11, height: 11)
    }
}
