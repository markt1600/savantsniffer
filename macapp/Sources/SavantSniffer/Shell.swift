import Foundation

// Runs local command-line tools (arp, nmap, arp-scan). Non-sandboxed local dev tool.
enum Shell {
    struct Result { var stdout: String; var stderr: String; var code: Int32 }

    static func which(_ name: String) -> String? {
        let candidates = ["/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/",
                          "/usr/sbin/", "/sbin/"]
        for dir in candidates {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        do { try proc.run() } catch {
            return Result(stdout: "", stderr: "launch failed: \(error)", code: -1)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Result(stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "",
                      code: proc.terminationStatus)
    }
}
