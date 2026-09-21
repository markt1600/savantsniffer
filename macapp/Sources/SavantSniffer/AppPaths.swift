import Foundation

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SavantSniffer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var deviceMap: URL { support.appendingPathComponent("devices.json") }
    static var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    static var captures: URL { support.appendingPathComponent("captures", isDirectory: true) }
}
