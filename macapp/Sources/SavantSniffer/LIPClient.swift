import Foundation
import Network
import Combine

/// Single, cleanly-closed LIP telnet session over Network.framework.
/// Observe-first: monitoring only enables event reporting; control is gated
/// behind an explicit confirmed call and never fires from the monitor path.
@MainActor
final class LIPClient: ObservableObject {
    enum State: Equatable { case idle, connecting, authenticating, monitoring, closed, failed(String) }

    @Published var state: State = .idle
    @Published var systemName: String = ""
    @Published var prompt: String = ""
    @Published var events: [MonitorEvent] = []
    @Published var lastError: String?

    let recorder = MacroRecorder()
    var onEvent: ((MonitorEvent) -> Void)?

    private var conn: NWConnection?
    private var buffer = Data()
    private var loggedIn = false
    private var host = ""
    private var user = "lutron"
    private var pass = "integration"
    private var logHandle: FileHandle?

    private let readyPrompts = ["QNET>", "GNET>", "QSE>"]
    private let promptSystem = ["QNET>": "HomeWorks QS", "GNET>": "RadioRA 2", "QSE>": "HomeWorks QS (QSE)"]

    // MARK: - lifecycle
    func connect(host: String, port: UInt16 = 23, user: String, pass: String) {
        disconnect()
        self.host = host; self.user = user; self.pass = pass
        self.loggedIn = false; self.buffer = Data(); self.events = []
        state = .connecting
        openLog()
        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                switch st {
                case .ready:
                    self?.state = .authenticating
                    self?.receiveLoop()
                case .failed(let e):
                    self?.state = .failed("\(e)"); self?.lastError = "\(e)"
                case .cancelled:
                    if case .failed = self?.state { } else { self?.state = .closed }
                default: break
                }
            }
        }
        c.start(queue: .global())
    }

    func disconnect() {
        conn?.cancel(); conn = nil
        closeLog()
        if state == .monitoring || state == .authenticating || state == .connecting {
            state = .closed
        }
    }

    // MARK: - IO
    private func send(_ line: String) {
        let data = (line + "\r\n").data(using: .utf8)!
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let data = data, !data.isEmpty { self.ingest(data) }
                if let error = error { self.state = .failed("\(error)"); self.lastError = "\(error)"; return }
                if isComplete { self.state = .closed; return }
                if self.conn != nil { self.receiveLoop() }
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)

        if !loggedIn {
            let text = String(decoding: buffer, as: UTF8.self)
            if text.lowercased().contains("login:") && !text.lowercased().contains("password:") {
                send(user); buffer.removeAll(); return
            }
            if text.lowercased().contains("password:") {
                send(pass); buffer.removeAll(); return
            }
            for p in readyPrompts where text.contains(p) {
                loggedIn = true
                prompt = p
                systemName = promptSystem[p] ?? "Lutron LIP"
                buffer.removeAll()
                enableMonitoring()
                state = .monitoring
                return
            }
            // A second login prompt after we already sent creds means auth failed.
            if text.components(separatedBy: "login:").count > 2 {
                let msg = "login rejected — default credentials likely wrong"
                state = .failed(msg); lastError = msg
            }
            return
        }

        // logged in: split complete lines
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            var line = String(data: lineData, encoding: .utf8) ?? ""
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\0 "))
            for p in readyPrompts where line.hasPrefix(p) {
                line = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }
            let ev = MonitorEvent.parse(line)
            if ev.kind == .device || ev.kind == .output {
                recorder.feed(ev)
                events.append(ev)
                if events.count > 1000 { events.removeFirst(events.count - 1000) }
                writeLog(ev)
                onEvent?(ev)
            }
        }
    }

    private func enableMonitoring() {
        send("#MONITORING,3,1")   // device/button events
        send("#MONITORING,5,1")   // output/zone level events
    }

    // MARK: - control (GATED)
    /// Sends a state-changing command. `confirmed` MUST be true (observe-first).
    @discardableResult
    func sendControl(_ command: String, confirmed: Bool) -> Bool {
        guard confirmed else { return false }
        guard command.hasPrefix("#OUTPUT") || command.hasPrefix("#DEVICE") else { return false }
        guard state == .monitoring else { return false }
        send(command)
        return true
    }

    /// Read-only query of a load's current level.
    func queryOutput(_ id: Int) { if state == .monitoring { send("?OUTPUT,\(id),1") } }

    // MARK: - logging
    private func openLog() {
        let dir = AppPaths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = ISO8601DateFormatter()
        let name = "monitor-" + f.string(from: Date()).replacingOccurrences(of: ":", with: "") + ".log"
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
    }
    private func writeLog(_ ev: MonitorEvent) {
        let line = ev.timeString + "  " + ev.raw + "\n"
        logHandle?.write(line.data(using: .utf8)!)
    }
    private func closeLog() { try? logHandle?.close(); logHandle = nil }
}
