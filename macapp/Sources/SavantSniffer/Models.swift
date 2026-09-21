import Foundation

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
    // parsed
    var integrationID: Int?
    var component: Int?     // button number for ~DEVICE
    var action: String?
    var level: Double?

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }

    var detail: String {
        switch kind {
        case .output: return "level \(level.map { String(format: "%g", $0) } ?? "?")"
        case .device: return "btn \(component.map(String.init) ?? "?") act \(action ?? "?")"
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
        var id: Int { position ?? label.hashValue }
        var position: Int?
        var button: Int?        // real LIP component id, filled by sniffing
        var label: String
        var kind: String        // output|macro|integration|shade|hvac|fan|rgb|dim
        var subsystem: String?
        var intent: String?
        var asBuilt: Bool?
        var remarks: String?
        var effect: [Effect]?
        var savantCaptured: Bool?   // integration buttons: Savant traffic recorded
        var savantNote: String?     // e.g. captured command / playlist / device

        /// Capture status used for the green-light dashboard.
        func status(keypadIdentified: Bool) -> CaptureStatus {
            let hasComponent = (button != nil)
            switch kind {
            case "integration":
                if hasComponent && (savantCaptured ?? false) { return .captured }
                if hasComponent { return .identified }   // press seen; Savant side still to do
                return keypadIdentified ? .identified : .pending
            case "macro":
                if hasComponent && (effect?.isEmpty == false) { return .captured }
                if hasComponent { return .identified }   // button known; burst not captured
                return keypadIdentified ? .identified : .pending
            default:
                if hasComponent { return .captured }
                return keypadIdentified ? .identified : .pending
            }
        }
    }

    enum CaptureStatus: String {
        case pending      // nothing captured yet
        case identified   // partially captured (button seen, effect/Savant still to do)
        case captured     // fully captured
    }
    struct Output: Codable, Identifiable {
        var id: String { name }
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
        // output/shade step
        var outputID: Int?
        var level: Double?
        // keypad press step
        var keypadID: Int?
        var button: Int?
        // savant integration replay step
        var savantHost: String?
        var savantPort: Int?
        var savantPayload: String?   // captured command text to replay
        // pause step
        var delayMs: Int?
        var note: String?
    }

    enum StepType: String, Codable, CaseIterable {
        case output       // #OUTPUT,<id>,1,<level>
        case press        // #DEVICE,<keypadID>,<button>,3
        case savant       // replay captured plain-TCP command
        case delay        // wait delayMs before the next step
    }

    /// Translate a step into the LIP command it will send (nil for delay/savant).
    static func lipCommand(for step: MacroStep) -> String? {
        switch step.type {
        case .output:
            guard let id = step.outputID, let lvl = step.level else { return nil }
            return String(format: "#OUTPUT,%d,1,%g", id, lvl)
        case .press:
            guard let k = step.keypadID, let b = step.button else { return nil }
            return "#DEVICE,\(k),\(b),3"
        case .savant, .delay:
            return nil
        }
    }
}

// MARK: - Macro capture

final class MacroRecorder {
    private(set) var active = false
    private(set) var triggerDevice: Int?
    private(set) var triggerButton: Int?
    private(set) var steps: [(id: Int, level: Double)] = []
    private var lastEvent = Date()

    func begin() {
        active = true; steps = []; triggerDevice = nil; triggerButton = nil
        lastEvent = Date()
    }
    func feed(_ ev: MonitorEvent) {
        guard active else { return }
        if ev.kind == .output, let i = ev.integrationID, let l = ev.level {
            steps.append((i, l)); lastEvent = Date()
        } else if ev.kind == .device {
            if triggerDevice == nil { triggerDevice = ev.integrationID; triggerButton = ev.component }
            lastEvent = Date()
        }
    }
    var settled: Bool { active && Date().timeIntervalSince(lastEvent) > 2.5 }
    func classify() -> String {
        let ids = Set(steps.map { $0.id })
        if ids.isEmpty { return "integration" }
        if ids.count == 1 { return "output" }
        return "macro"
    }
    func effect() -> [DeviceMap.Effect] {
        var last: [Int: Double] = [:]
        for s in steps { last[s.id] = s.level }
        return last.map { DeviceMap.Effect(id: $0.key, level: $0.value) }
    }
    func finish() { active = false }
}
