import Foundation
import Network
import Combine

/// Single, cleanly-closed LIP telnet session over Network.framework.
/// Observe-first: monitoring only enables event reporting; control is gated
/// behind an explicit confirmed call and never fires from the monitor path.
@MainActor
final class LIPClient: ObservableObject {
    enum State: Equatable { case idle, connecting, authenticating, monitoring, closed, failed(String) }
    private enum LoginPhase { case awaitLogin, awaitPassword, awaitPrompt, done }
    enum Transport { case telnet, external }   // external = the LEAP bridge feeding the same hub

    @Published var state: State = .idle
    @Published var systemName: String = ""
    @Published var prompt: String = ""
    @Published var events: [MonitorEvent] = []
    @Published var lastError: String?
    @Published var connectedSince: Date?

    let recorder = MacroRecorder()
    var onEvent: ((MonitorEvent) -> Void)?
    private(set) var transport: Transport = .telnet
    var externalSend: ((String) -> Bool)?   // set by the LEAP bridge
    var externalStop: (() -> Void)?

    private var conn: NWConnection?
    private var generation = 0          // invalidates timeouts from earlier connects
    private var buffer = Data()
    private var phase: LoginPhase = .awaitLogin
    private var user = "lutron"
    private var pass = "integration"
    private var logHandle: FileHandle?

    private let readyPrompts = ["QNET>", "GNET>", "QSE>"]
    private let promptSystem = ["QNET>": "HomeWorks QS", "GNET>": "RadioRA 2", "QSE>": "HomeWorks QS (QSE)"]

    var isLive: Bool { state == .monitoring }

    // MARK: - lifecycle

    func connect(host: String, port: UInt16 = 23, user: String, pass: String) {
        disconnect()
        self.user = user; self.pass = pass
        phase = .awaitLogin; buffer = Data(); events = []; lastError = nil
        systemName = ""; prompt = ""; connectedSince = nil
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("invalid port \(port)"); return
        }
        state = .connecting
        openLog()
        generation += 1
        let gen = generation
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                // Ignore callbacks from a connection we have already replaced or dropped.
                guard let self, self.conn === c else { return }
                switch st {
                case .ready:
                    self.state = .authenticating
                    self.receiveLoop(on: c)
                case .failed(let e):
                    self.fail(Self.explain(e, host: host, port: port))
                case .waiting(let e):
                    // A LAN processor answers at once. "Waiting" means refused or
                    // unreachable, and NWConnection would retry silently forever.
                    self.fail(Self.explain(e, host: host, port: port))
                case .cancelled:
                    if case .failed = self.state {} else { self.state = .closed }
                default:
                    break
                }
            }
        }
        c.start(queue: .global())

        // Hard stop: no login prompt within 10 s means nothing is talking LIP here.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.generation == gen, self.conn === c else { return }
            if self.state == .connecting || self.state == .authenticating {
                let why = self.state == .connecting
                    ? "no answer on \(host):\(port) within 10 s (port closed or filtered)"
                    : "connected to \(host):\(port) but no login prompt arrived — not a LIP telnet service"
                self.fail(why)
            }
        }
    }

    /// Turn an NWError into advice.
    nonisolated private static func explain(_ e: NWError, host: String, port: UInt16) -> String {
        let text = "\(e)"
        if case .posix(let code) = e {
            switch code {
            case .ECONNREFUSED:
                return "\(host) refused port \(port). No telnet (LIP) service here: a LEAP-generation device, or LIP integration is disabled on the processor."
            case .EHOSTUNREACH, .ENETUNREACH:
                return "\(host) is unreachable from this Mac (wrong subnet or VLAN?)."
            case .ETIMEDOUT:
                return "\(host):\(port) timed out (filtered, or asleep)."
            default:
                break
            }
        }
        return text
    }

    // MARK: - external transport (LEAP bridge)

    func attachExternal(systemName: String) {
        if transport == .telnet { let old = conn; conn = nil; old?.cancel() }
        transport = .external
        self.systemName = systemName; prompt = "LEAP"
        events = []; lastError = nil
        openLog()
        state = .monitoring
        connectedSince = Date()
    }

    func detachExternal(reason: String?) {
        guard transport == .external else { return }
        transport = .telnet
        closeLog(); recorder.finish(); connectedSince = nil
        if let r = reason { state = .failed(r); lastError = r } else { state = .closed }
    }

    func ingestExternalLine(_ line: String) { handleLine(line) }

    /// Translate a LIP-shaped control command into the bridge's command line.
    nonisolated static func bridgeCommand(for lip: String) -> String? {
        let p = lip.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        if p.first == "#OUTPUT", p.count >= 4, p[2] == "1" {
            return "SET \(p[1]) \(p[3])" + (p.count >= 5 ? " \(p[4])" : "")
        }
        if p.first == "#DEVICE", p.count >= 4, p[3] == "3" {
            return "PRESS \(p[1]) \(p[2])"
        }
        return nil
    }

    func disconnect() {
        if transport == .external {
            externalStop?()
            detachExternal(reason: nil)
            return
        }
        let old = conn
        conn = nil                 // stale callbacks are ignored from here on
        old?.cancel()
        closeLog()
        recorder.finish()
        connectedSince = nil
        if case .failed = state {} else if state != .idle { state = .closed }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        lastError = message
        let old = conn
        conn = nil
        old?.cancel()
        closeLog()
        recorder.finish()
        connectedSince = nil
    }

    // MARK: - IO

    private func send(_ line: String) {
        guard let c = conn, let data = (line + "\r\n").data(using: .utf8) else { return }
        c.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.conn === c else { return }
                if let data, !data.isEmpty { self.ingest(data) }
                if let error { self.fail("\(error)"); return }
                if isComplete { self.state = .closed; self.conn = nil; self.closeLog(); return }
                if self.conn === c { self.receiveLoop(on: c) }
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        if phase != .done {
            handleLogin()
            if phase != .done { return }
        }
        drainLines()
    }

    // Byte-based prompt matching (telnet may carry non-UTF-8 negotiation bytes,
    // so string offsets are unreliable; Data offsets are exact).
    private func lowercasedBytes() -> Data {
        Data(buffer.map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 })
    }
    private func find(_ token: String, caseInsensitive: Bool) -> Range<Int>? {
        let hay = caseInsensitive ? lowercasedBytes() : Data(buffer)
        let needle = Data((caseInsensitive ? token.lowercased() : token).utf8)
        guard let r = hay.range(of: needle) else { return nil }
        return r.lowerBound..<r.upperBound
    }
    private func consume(through end: Int) {
        buffer = Data(buffer[end...])
    }

    private func handleLogin() {
        while phase != .done {
            switch phase {
            case .awaitLogin:
                guard let r = find("login:", caseInsensitive: true) else { return }
                consume(through: r.upperBound)
                send(user)
                phase = .awaitPassword
            case .awaitPassword:
                guard let r = find("password:", caseInsensitive: true) else { return }
                consume(through: r.upperBound)
                send(pass)
                phase = .awaitPrompt
            case .awaitPrompt:
                var best: (prompt: String, range: Range<Int>)?
                for p in readyPrompts {
                    if let r = find(p, caseInsensitive: false),
                       best == nil || r.lowerBound < best!.range.lowerBound {
                        best = (p, r)
                    }
                }
                if let b = best {
                    // A second "login:" BEFORE the prompt means the credentials were rejected.
                    if let l = find("login:", caseInsensitive: true), l.lowerBound < b.range.lowerBound {
                        phase = .done
                        fail("login rejected — check the user name and password")
                        return
                    }
                    consume(through: b.range.upperBound)   // keep any event bytes after it
                    prompt = b.prompt
                    systemName = promptSystem[b.prompt] ?? "Lutron LIP"
                    phase = .done
                    enableMonitoring()
                    state = .monitoring
                    connectedSince = Date()
                } else if find("login:", caseInsensitive: true) != nil {
                    phase = .done
                    fail("login rejected — check the user name and password")
                    return
                } else {
                    return
                }
            case .done:
                return
            }
        }
    }

    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[(nl + 1)...])
            handleLine(String(decoding: lineData, as: UTF8.self))
        }
    }

    /// One line from either transport: strip prompts, parse, record.
    private func handleLine(_ raw: String) {
        var line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\0 "))
        var stripped = true
        while stripped {
            stripped = false
            for p in readyPrompts where line.hasPrefix(p) {
                line = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        guard !line.isEmpty else { return }
        var ev = MonitorEvent.parse(line)
        guard ev.kind == .device || ev.kind == .output else { return }
        ev.capturing = recorder.active
        recorder.feed(ev)
        events.append(ev)
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
        writeLog(ev)
        onEvent?(ev)
    }

    private func enableMonitoring() {
        send("#MONITORING,3,1")   // device/button events -> ~DEVICE
        send("#MONITORING,5,1")   // output/zone level events -> ~OUTPUT
    }

    // MARK: - control (GATED)

    /// Sends a state-changing command. `confirmed` MUST be true (observe-first).
    @discardableResult
    func sendControl(_ command: String, confirmed: Bool) -> Bool {
        guard confirmed else { return false }
        guard command.hasPrefix("#OUTPUT") || command.hasPrefix("#DEVICE") else { return false }
        guard state == .monitoring else { return false }
        if transport == .external {
            guard let cmd = Self.bridgeCommand(for: command) else { return false }
            return externalSend?(cmd) ?? false
        }
        send(command)
        return true
    }

    /// Read-only query of a load's current level (telnet only; LEAP pushes levels itself).
    func queryOutput(_ id: Int) { if state == .monitoring && transport == .telnet { send("?OUTPUT,\(id),1") } }

    // MARK: - logging

    private func openLog() {
        let dir = AppPaths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("monitor-" + f.string(from: Date()) + ".log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
    }
    private func writeLog(_ ev: MonitorEvent) {
        if let d = (ev.timeString + "  " + ev.raw + "\n").data(using: .utf8) { logHandle?.write(d) }
    }
    private func closeLog() { try? logHandle?.close(); logHandle = nil }
}
