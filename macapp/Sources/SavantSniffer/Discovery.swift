import Foundation
import Combine

@MainActor
final class DiscoveryModel: ObservableObject {
    @Published var subnet: String = ""
    @Published var scanCommand: String = ""
    @Published var toolName: String = ""
    @Published var note: String = ""
    @Published var needsSudo = false
    @Published var hosts: [DiscoveredHost] = []
    @Published var scanning = false
    @Published var lastError: String?

    struct Tool { var name: String; var present: Bool; var path: String?; var hint: String }
    @Published var tools: [Tool] = []

    init() {
        detectSubnet()
        refreshTools()
        buildCommand()
    }

    func refreshTools() {
        let hints = ["nmap": "brew install nmap",
                     "arp-scan": "brew install arp-scan",
                     "arp": "preinstalled on macOS",
                     "tcpdump": "preinstalled on macOS",
                     "tshark": "brew install --cask wireshark"]
        tools = ["nmap","arp-scan","arp","tcpdump","tshark"].map {
            let p = Shell.which($0)
            return Tool(name: $0, present: p != nil, path: p, hint: hints[$0] ?? "")
        }
    }

    var preferredTool: String {
        if Shell.which("arp-scan") != nil { return "arp-scan" }
        if Shell.which("nmap") != nil { return "nmap" }
        return "arp"
    }

    func detectSubnet() {
        if let ip = Self.primaryIPv4() {
            var comps = ip.split(separator: ".").map(String.init)
            if comps.count == 4 { comps[3] = "0"; subnet = comps.joined(separator: ".") + "/24" }
        }
        if subnet.isEmpty { subnet = "192.168.1.0/24" }
    }

    /// The exact command line that will run (shown for approval, then executed as-is).
    func buildCommand() {
        let tool = preferredTool
        toolName = tool
        switch tool {
        case "arp-scan":
            scanCommand = "\(Shell.which("arp-scan") ?? "arp-scan") \(subnet)"
            needsSudo = true
            note = "Fast layer-2 scan; returns IP + MAC + vendor. macOS will ask for your password."
        case "nmap":
            scanCommand = "\(Shell.which("nmap") ?? "nmap") -sn \(subnet)"
            needsSudo = true
            note = "Ping sweep; runs as root so MAC addresses are included. macOS will ask for your password."
        default:
            scanCommand = "arp -a"
            needsSudo = false
            note = "Reads the existing ARP cache only (no active scan)."
        }
    }

    func runScan() {
        scanning = true; lastError = nil; hosts = []
        let tool = toolName
        let command = scanCommand
        let privileged = needsSudo
        Task.detached {
            let result: Shell.Result
            if privileged {
                // Runs the SAME command the user approved, via the native admin prompt.
                result = Shell.runPrivileged(command)
            } else if let p = Shell.which("arp") {
                result = Shell.run(p, ["-a"])
            } else {
                result = Shell.Result(stdout: "", stderr: "arp not found", code: -1)
            }
            let parsed = Self.parse(tool: tool, text: result.stdout + "\n" + result.stderr)
            let sorted = parsed.sorted { rank($0.classification) < rank($1.classification) }
            let err: String? = (parsed.isEmpty && (result.code != 0 || !result.stderr.isEmpty))
                ? (result.stderr.isEmpty ? "scan produced no hosts (exit \(result.code))" : result.stderr)
                : nil
            await MainActor.run {
                self.hosts = sorted
                self.scanning = false
                self.lastError = err
            }
        }
    }

    // MARK: - parsing (nonisolated: called from the detached task)

    nonisolated static func parse(tool: String, text: String) -> [DiscoveredHost] {
        var out: [DiscoveredHost] = []
        let lines = text.components(separatedBy: .newlines)
        if tool == "arp-scan" {
            for line in lines {
                let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                    .map(String.init).filter { !$0.isEmpty }
                if cols.count >= 2, isIP(cols[0]), isMAC(cols[1]) {
                    let vendor = cols.count > 2 ? cols[2...].joined(separator: " ") : ""
                    out.append(host(cols[0], cols[1], vendor))
                }
            }
        } else if tool == "nmap" {
            var currentIP: String?
            for line in lines {
                if line.contains("Nmap scan report"),
                   let r = line.range(of: #"(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    currentIP = String(line[r])
                }
                if line.contains("MAC Address:"),
                   let macR = line.range(of: #"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"#, options: .regularExpression),
                   let ip = currentIP {
                    let mac = String(line[macR])
                    var vendor = ""
                    if let vR = line.range(of: #"\((.*?)\)"#, options: .regularExpression) {
                        vendor = String(line[vR]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    }
                    out.append(host(ip, mac, vendor))
                    currentIP = nil
                }
            }
        } else { // arp -a
            for line in lines {
                guard let ipR = line.range(of: #"(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression),
                      let macR = line.range(of: #"([0-9a-fA-F]{1,2}[:-]){5}[0-9a-fA-F]{1,2}"#,
                                            options: .regularExpression)
                else { continue }
                let mac = String(line[macR]).replacingOccurrences(of: "-", with: ":")
                if mac.lowercased().hasPrefix("ff:ff") { continue }   // broadcast entries
                out.append(host(String(line[ipR]), mac, ""))
            }
        }
        return out
    }

    nonisolated private static func host(_ ip: String, _ mac: String, _ vendor: String) -> DiscoveredHost {
        DiscoveredHost(ip: ip, mac: mac, vendor: vendor,
                       classification: OUI.classify(mac: mac, vendorHint: vendor))
    }
    nonisolated private static func isIP(_ s: String) -> Bool {
        s.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }
    nonisolated private static func isMAC(_ s: String) -> Bool {
        s.range(of: #"^([0-9a-fA-F]{1,2}[:-]){5}[0-9a-fA-F]{1,2}$"#, options: .regularExpression) != nil
    }

    nonisolated static func primaryIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr,
               (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: cur.pointee.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                                   socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: host)
                        break
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return address
    }
}

private func rank(_ c: String) -> Int {
    switch c { case "Lutron": return 0; case "Apple": return 1; default: return 2 }
}
