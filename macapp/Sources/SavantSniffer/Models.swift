import Foundation
import Combine

// MARK: - Discovery

struct DiscoveredHost: Identifiable, Hashable {
    var id: String { ip + mac }
    var ip: String
    var mac: String
    var vendor: String
    var classification: String   // "Lutron" | "Apple" | "unknown"
}

// MARK: - Port check

struct PortResult: Identifiable {
    var id: Int { port }
    var port: Int
    var open: Bool
    var detail: String
}

let PORT_LABELS: [Int: String] = [
    23: "telnet / LIP (HomeWorks QS, RadioRA 2)",
    8081: "LEAP over TLS (QSX, RadioRA 3, Caseta)",
    8083: "LEAP web / secondary (often QSX)"
]

// MARK: - Monitor events

enum EventKind: String {
    case device = "DEVICE"
    case output = "OUTPUT"
    case status = "STATUS"
    case error = "ERROR"
    case other = "OTHER"
}

struct MonitorEvent: Identifiable {
    let id = UUID()
    var timestamp: Date
    var kind: EventKind
    var raw: String
    var integrationID: Int?
    var component: Int?     // button number for ~DEVICE
    var action: String?
    var level: Double?
    var capturing = false   // arrived while a macro capture was armed

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }

    var detail: String {
        switch kind {
        case .output:
            if let l = level { return "level " + String(format: "%g", l) }
            return "level ?"
        case .device:
            let b = component.map { String($0) } ?? "?"
            let a = (action == "3") ? "press" : (action == "4" ? "release" : (action ?? "?"))
            return "btn \(b) · \(a)"
        default: return ""
        }
    }

    static func parse(_ line: String, at date: Date = Date()) -> MonitorEvent {
        var kind: EventKind = .other
        if line.hasPrefix("~DEVICE") { kind = .device }
        else if line.hasPrefix("~OUTPUT") { kind = .output }
        var ev = MonitorEvent(timestamp: date, kind: kind, raw: line)
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if kind == .device, parts.count >= 4 {
            ev.integrationID = Int(parts[1])
            ev.component = Int(parts[2])
            ev.action = parts[3].trimmingCharacters(in: .whitespaces)
        } else if kind == .output, parts.count >= 4 {
            ev.integrationID = Int(parts[1])
            ev.action = parts[2]
            ev.level = Double(parts[3].trimmingCharacters(in: .whitespaces))
        }
        return ev
    }
}

// MARK: - Device map (Codable, mirrors layout.seed.json)

struct DeviceMap: Codable {
    var system: String?
    var processor: String?
    var savantHost: String?
    var accessOK: Bool?      // LIP login succeeded or LEAP paired
    var source: String?
    var areas: [Area]
    var customMacros: [CustomMacro]?

    struct Area: Codable, Identifiable {
        var id: String { name }
        var name: String
        var keypads: [Keypad]
        var outputs: [Output]
    }
    struct Keypad: Codable, Identifiable {
        var id: String { name }
        var name: String
        var lutronID: Int?
        var buttons: [Button]
        enum CodingKeys: String, CodingKey {
            case name; case lutronID = "id"; case buttons
        }
    }
    struct Button: Codable, Identifiable {
        var id: String { "\(position ?? -1)-\(label)" }
        var position: Int?
        var button: Int?        // real LIP component id, filled by sniffing
        var label: String
        var kind: String        // output|macro|integration|shade|hvac|fan|rgb|dim
        var subsystem: String?
        var intent: String?
        var asBuilt: Bool?
        var remarks: String?
        var effect: [Effect]?
        var savantCaptured: Bool?
        var savantNote: String?
        var audioZones: [String]?   // zones this button drives on the Savant side
        var audioSource: String?    // e.g. "home office input"

        func status(keypadIdentified: Bool) -> CaptureStatus {
            let hasComponent = (button != nil)
            switch kind {
            case "integration":
                if hasComponent && (savantCaptured ?? false) { return .captured }
                if hasComponent { return .identified }
                return keypadIdentified ? .identified : .pending
            case "macro":
                if hasComponent && (effect?.isEmpty == false) { return .captured }
                if hasComponent { return .identified }
                return keypadIdentified ? .identified : .pending
            default:
                if hasComponent { return .captured }
                return keypadIdentified ? .identified : .pending
            }
        }
    }

    enum CaptureStatus: String {
        case pending, identified, captured
    }

    struct Output: Codable, Identifiable {
        var id: String { "\(lutronID)-\(name)" }
        var name: String
        var lutronID: Int
        var kind: String
        enum CodingKeys: String, CodingKey {
            case name; case lutronID = "id"; case kind
        }
    }
    struct Effect: Codable {
        var id: Int
        var level: Double
    }
}

// MARK: - Custom macros (user-defined scenes built from captured devices)

struct CustomMacro: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var steps: [MacroStep]

    struct MacroStep: Codable, Identifiable {
        var id: UUID = UUID()
        var type: StepType
        var outputID: Int?
        var level: Double?
        var fadeSeconds: Double?   // optional ramp time for output steps
        var keypadID: Int?
        var button: Int?
        var savantHost: String?
        var savantPort: Int?
        var savantPayload: String?
        var delayMs: Int?
        var note: String?
    }

    enum StepType: String, Codable, CaseIterable {
        case output, press, savant, delay
    }

    /// The LIP command a step sends (nil for delay/savant).
    static func lipCommand(for step: MacroStep) -> String? {
        switch step.type {
        case .output:
            guard let id = step.outputID, let lvl = step.level else { return nil }
            if let fade = step.fadeSeconds, fade > 0 {
                return String(format: "#OUTPUT,%d,1,%g,%g", id, lvl, fade)   // level + fade seconds
            }
            return String(format: "#OUTPUT,%d,1,%g", id, lvl)
        case .press:
            guard let k = step.keypadID, let b = step.button else { return nil }
            return "#DEVICE,\(k),\(b),3"
        case .savant, .delay:
            return nil
        }
    }

    /// Human-readable preview line for each step ("will send").
    static func previewLine(for step: MacroStep) -> String {
        switch step.type {
        case .output, .press: return lipCommand(for: step) ?? "(incomplete step)"
        case .savant:
            let h = step.savantHost ?? "?"; let p = step.savantPort.map { String($0) } ?? "?"
            return "tcp \(h):\(p) ← \(step.savantPayload ?? "")"
        case .delay: return "wait \(step.delayMs ?? 0)ms"
        }
    }
}

// MARK: - Macro capture (observable so the UI updates as the burst arrives)

@MainActor
final class MacroRecorder: ObservableObject {
    struct Step { var id: Int; var level: Double }

    @Published private(set) var active = false
    @Published private(set) var triggerDevice: Int?
    @Published private(set) var triggerButton: Int?
    @Published private(set) var steps: [Step] = []
    private var lastEvent = Date()

    func begin() {
        active = true; steps = []; triggerDevice = nil; triggerButton = nil
        lastEvent = Date()
    }
    func feed(_ ev: MonitorEvent) {
        guard active else { return }
        if ev.kind == .output, let i = ev.integrationID, let l = ev.level {
            steps.append(Step(id: i, level: l)); lastEvent = Date()
        } else if ev.kind == .device {
            if triggerDevice == nil { triggerDevice = ev.integrationID; triggerButton = ev.component }
            lastEvent = Date()
        }
    }
    var settled: Bool { active && Date().timeIntervalSince(lastEvent) > 2.5 }
    var loadsAffected: Int { Set(steps.map { $0.id }).count }
    func classify() -> String {
        let ids = Set(steps.map { $0.id })
        if ids.isEmpty { return "integration" }
        if ids.count == 1 { return "output" }
        return "macro"
    }
    func effect() -> [DeviceMap.Effect] {
        var last: [Int: Double] = [:]
        for s in steps { last[s.id] = s.level }
        return last.keys.sorted().map { DeviceMap.Effect(id: $0, level: last[$0]!) }
    }
    func finish() { active = false }
}
