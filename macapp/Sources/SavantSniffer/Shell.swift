import Foundation

/// Runs local command-line tools. Non-sandboxed local developer tool.
enum Shell {
    struct Result { var stdout: String; var stderr: String; var code: Int32 }

    static func which(_ name: String) -> String? {
        let dirs = ["/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/usr/sbin/", "/sbin/"]
        for dir in dirs {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Run a binary. stdout and stderr are drained concurrently (no pipe deadlock)
    /// and the process is terminated if it exceeds `timeout`.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        do { try proc.run() } catch {
            return Result(stdout: "", stderr: "launch failed: \(error.localizedDescription)", code: -1)
        }
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()
        errDone.wait()
        return Result(stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      code: proc.terminationStatus)
    }

    /// Run a command line with administrator rights via the native macOS auth
    /// prompt (osascript "with administrator privileges"). The user sees exactly
    /// the command they approved, and macOS asks for their password.
    static func runPrivileged(_ commandLine: String, timeout: TimeInterval = 180) -> Result {
        let escaped = commandLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }
}
