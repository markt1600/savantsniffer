import Foundation
import Combine

/// Runs the bundled leap_bridge.py in a private virtualenv and turns its line
/// protocol into the same event stream the telnet client produces.
@MainActor
final class LEAPBridge: ObservableObject {
    @Published var log: [String] = []
    @Published var busy = false
    @Published var envReady = false
    @Published var paired = false
    @Published var serving = false
    @Published var lastError: String?

    private var serveProcess: Process?
    private var serveStdin: FileHandle?

    let pythonPath: String? = Shell.which("python3")
    var venvDir: URL { AppPaths.support.appendingPathComponent("leap-venv", isDirectory: true) }
    var certDir: URL { AppPaths.support.appendingPathComponent("leap", isDirectory: true) }
    var venvPython: String { venvDir.appendingPathComponent("bin/python3").path }
    private var markerPath: String { venvDir.appendingPathComponent(".pylutron-installed").path }
    var scriptPath: String? { Bundle.module.url(forResource: "leap_bridge", withExtension: "py")?.path }

    init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        envReady = fm.isExecutableFile(atPath: venvPython) && fm.fileExists(atPath: markerPath)
        paired = ["caseta.key", "caseta.crt", "caseta-bridge.crt"].allSatisfy {
            fm.fileExists(atPath: certDir.appendingPathComponent($0).path)
        }
    }

    private func note(_ s: String) {
        log.append(s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: - environment

    /// Create the virtualenv and install pylutron-caseta into it (needs internet once).
    func setup() {
        guard !busy else { return }
        guard let py = pythonPath else { lastError = "python3 not found. Install Xcode's command line tools (xcode-select --install)."; return }
        busy = true; lastError = nil
        note("Creating private Python environment…")
        let venv = venvDir.path, venvPy = venvPython, marker = markerPath
        Task.detached {
            let r1 = Shell.run(py, ["-m", "venv", venv], timeout: 180)
            if r1.code != 0 {
                await MainActor.run { self.note("ERR venv: " + r1.stderr); self.lastError = "could not create the Python environment"; self.busy = false }
                return
            }
            await MainActor.run { self.note("Installing pylutron-caseta (downloads from PyPI)…") }
            let r2 = Shell.run(venvPy, ["-m", "pip", "install", "--quiet", "--upgrade", "pip", "pylutron-caseta"], timeout: 600)
            if r2.code != 0 {
                await MainActor.run { self.note("ERR pip: " + r2.stderr.suffix(600)); self.lastError = "pip install failed (see log)"; self.busy = false }
                return
            }
            FileManager.default.createFile(atPath: marker, contents: Data())
            await MainActor.run { self.note("Environment ready."); self.busy = false; self.refresh() }
        }
    }

    // MARK: - pairing

    func pair(host: String, onDone: @escaping (Bool) -> Void) {
        guard !busy, let script = scriptPath else { return }
        busy = true; lastError = nil
        note("Pairing with \(host). Press the pairing button on the processor when asked.")
        runStreaming([script, "pair", host, "--dir", certDir.path]) { [weak self] line in
            self?.note(line)
        } onExit: { [weak self] code in
            guard let self else { return }
            self.busy = false
            self.refresh()
            if code == 0 && self.paired { self.note("Paired.") } else { self.lastError = "pairing failed (see log)" }
            onDone(code == 0 && self.paired)
        }
    }

    // MARK: - device tree

    func importTree(host: String, onDone: @escaping (Data?) -> Void) {
        guard !busy, let script = scriptPath else { return }
        busy = true; lastError = nil
        note("Reading the device tree from \(host)…")
        var jsonLine: String?
        runStreaming([script, "tree", host, "--dir", certDir.path]) { [weak self] line in
            if line.hasPrefix("{") { jsonLine = line } else { self?.note(line) }
        } onExit: { [weak self] code in
            guard let self else { return }
            self.busy = false
            if code == 0, let j = jsonLine { onDone(j.data(using: .utf8)) }
            else { self.lastError = "could not read the device tree (see log)"; onDone(nil) }
        }
    }

    // MARK: - live session

    func startServe(host: String, lip: LIPClient) {
        guard serveProcess == nil, let script = scriptPath else { return }
        lastError = nil
        note("Starting live session with \(host)…")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = [script, "serve", host, "--dir", certDir.path]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe; proc.standardOutput = outPipe; proc.standardError = errPipe
        serveStdin = inPipe.fileHandleForWriting
        var lastErr = ""
        attachLineReader(outPipe.fileHandleForReading) { [weak self, weak lip] line in
            guard let self, let lip else { return }
            if line.hasPrefix("READY") {
                self.serving = true
                lip.attachExternal(systemName: "LEAP " + line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                self.note("Live.")
            } else if line.hasPrefix("~") {
                lip.ingestExternalLine(line)
            } else if line.hasPrefix("ERR") {
                lastErr = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                self.note(line)
            } else {
                self.note(line)
            }
        }
        attachLineReader(errPipe.fileHandleForReading) { [weak self] line in self?.note("py: " + line) }
        proc.terminationHandler = { [weak self, weak lip] p in
            Task { @MainActor in
                guard let self else { return }
                self.serving = false
                self.serveProcess = nil
                self.serveStdin = nil
                let failed = p.terminationStatus != 0
                lip?.detachExternal(reason: failed ? (lastErr.isEmpty ? "LEAP session ended (exit \(p.terminationStatus))" : lastErr) : nil)
                self.note(failed ? "Session ended with an error." : "Session closed.")
            }
        }
        lip.externalSend = { [weak self] cmd in self?.send(cmd) ?? false }
        lip.externalStop = { [weak self] in self?.stopServe() }
        do { try proc.run(); serveProcess = proc } catch {
            lastError = "could not start: \(error.localizedDescription)"
        }
    }

    func stopServe() {
        _ = send("QUIT")
        serveProcess?.terminate()
        serveProcess = nil
        serveStdin = nil
        serving = false
    }

    @discardableResult
    func send(_ cmd: String) -> Bool {
        guard let h = serveStdin, let d = (cmd + "\n").data(using: .utf8) else { return false }
        h.write(d)
        return true
    }

    // MARK: - process helpers

    private func runStreaming(_ args: [String], onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        attachLineReader(out.fileHandleForReading, onLine)
        attachLineReader(err.fileHandleForReading) { onLine("py: " + $0) }
        proc.terminationHandler = { p in Task { @MainActor in onExit(p.terminationStatus) } }
        do { try proc.run() } catch {
            note("ERR could not start python: \(error.localizedDescription)")
            busy = false
            onExit(-1)
        }
    }

    /// Deliver complete lines to the main actor as they arrive.
    private func attachLineReader(_ handle: FileHandle, _ onLine: @escaping @MainActor (String) -> Void) {
        var buffer = Data()
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r "))
                buffer = Data(buffer[(nl + 1)...])
                if !line.isEmpty { Task { @MainActor in onLine(line) } }
            }
        }
    }
}
