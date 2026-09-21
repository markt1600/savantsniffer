import Foundation
import Network
import Security
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
    @Published var progress: String = ""
    @Published var progressFraction: Double = 0     // 0…1 while sweeping
    @Published var candidatesSoFar = 0               // hosts answering on 23/8081 so far
    @Published var lastError: String?

    struct Tool { var name: String; var present: Bool; var path: String?; var hint: String }
    @Published var tools: [Tool] = []

    init() {
        detectSubnet()
        refreshTools()
        buildCommand()
    }

    func refreshTools() {
        let hints = ["nmap": "brew install nmap", "arp-scan": "brew install arp-scan",
                     "arp": "preinstalled on macOS", "tcpdump": "preinstalled on macOS",
                     "tshark": "brew install --cask wireshark"]
        tools = ["nmap","arp-scan","arp","tcpdump","tshark"].map {
            let p = Shell.which($0)
            return Tool(name: $0, present: p != nil, path: p, hint: hints[$0] ?? "")
        }
    }

    func detectSubnet() {
        if let ip = Self.primaryIPv4() {
            var comps = ip.split(separator: ".").map(String.init)
            if comps.count == 4 { comps[3] = "0"; subnet = comps.joined(separator: ".") + "/24" }
        }
        if subnet.isEmpty { subnet = "192.168.1.0/24" }
    }

    /// The built-in sweep needs no extra tools and no admin rights: it opens a TCP
    /// connection to every address on the /24 on ports 23 and 8081 (the two Lutron
    /// integration ports), which also populates the ARP cache, then reads `arp -a`
    /// for MAC addresses and looks each one up in the IEEE vendor registry.
    func buildCommand() {
        toolName = "sweep"
        needsSudo = false
        scanCommand = "TCP connect to \(subnet) ports 23 + 8081 (1s timeout each), then: arp -a"
        note = "Built in, no install, no password. Finds the Lutron processor by its telnet login prompt even if it never talks to this Mac."
    }

    var privilegedCommand: String? {
        if let p = Shell.which("arp-scan") { return "\(p) \(subnet)" }
        if let p = Shell.which("nmap") { return "\(p) -sn \(subnet)" }
        return nil
    }

    // MARK: - built-in sweep

    struct SweepResult: Sendable { var ip: String; var open23: Bool; var login: Bool; var banner: String; var open8081: Bool; var tlsSubject: String }

    func runSweep() {
        scanning = true; lastError = nil; hosts = []
        progress = "starting…"; progressFraction = 0; candidatesSoFar = 0
        let subnet = self.subnet
        Task.detached {
            let ips = Self.expand(subnet)
            var results: [String: SweepResult] = [:]
            var done = 0
            var found = 0
            await withTaskGroup(of: SweepResult.self) { group in
                var it = ips.makeIterator()
                for _ in 0..<48 {
                    if let ip = it.next() { group.addTask { await Self.sweepOne(ip) } }
                }
                for await r in group {
                    results[r.ip] = r
                    done += 1
                    if r.open23 || r.open8081 { found += 1 }
                    if done % 4 == 0 || done == ips.count {
                        let d = done, n = ips.count, f = found
                        await MainActor.run {
                            self.progress = "checked \(d) of \(n) addresses"
                            self.progressFraction = Double(d) / Double(max(n, 1))
                            self.candidatesSoFar = f
                        }
                    }
                    if let ip = it.next() { group.addTask { await Self.sweepOne(ip) } }
                }
            }
            await MainActor.run { self.progress = "reading MAC addresses…"; self.progressFraction = 1 }
            // MACs from the ARP cache the sweep just populated.
            let arpText = Shell.which("arp").map { Shell.run($0, ["-a"]).stdout } ?? ""
            var byIP: [String: DiscoveredHost] = [:]
            for h in Self.parse(tool: "arp", text: arpText) where !h.ip.hasPrefix("169.254.") {
                byIP[h.ip] = h
            }
            for (ip, r) in results where r.open23 || r.open8081 {
                if byIP[ip] == nil {
                    byIP[ip] = DiscoveredHost(ip: ip, mac: "", vendor: "", classification: "unknown")
                }
            }
            for (ip, r) in results {
                byIP[ip]?.lipOpen = r.open23
                byIP[ip]?.lipLogin = r.login
                byIP[ip]?.leapOpen = r.open8081
                byIP[ip]?.banner = r.banner
                byIP[ip]?.tlsSubject = r.tlsSubject
            }
            let sorted = byIP.values.sorted { a, b in
                let ra = rank(a), rb = rank(b)
                return ra != rb ? ra < rb : ipKey(a.ip).lexicographicallyPrecedes(ipKey(b.ip))
            }
            await MainActor.run {
                self.hosts = sorted
                self.scanning = false
                self.progress = ""
                if sorted.isEmpty { self.lastError = "No hosts found. Check the subnet." }
            }
        }
    }

    /// Optional privileged scan (arp-scan / nmap) via the native admin prompt.
    func runPrivileged() {
        guard let command = privilegedCommand else { return }
        scanning = true; lastError = nil; hosts = []; progress = "waiting for admin approval…"
        let tool = command.contains("arp-scan") ? "arp-scan" : "nmap"
        Task.detached {
            let result = Shell.runPrivileged(command)
            let parsed = Self.parse(tool: tool, text: result.stdout + "\n" + result.stderr)
            let sorted = parsed.sorted { rank($0) < rank($1) }
            await MainActor.run {
                self.hosts = sorted
                self.scanning = false
                self.progress = ""
                if parsed.isEmpty { self.lastError = result.stderr.isEmpty ? "scan produced no hosts" : result.stderr }
            }
        }
    }

    nonisolated static func sweepOne(_ ip: String) async -> SweepResult {
        async let a = bannerProbe(ip, port: 23)
        async let b = tlsProbe(ip, port: 8081)
        let (open23, banner) = await a
        let (open8081, subject) = await b
        return SweepResult(ip: ip, open23: open23, login: banner.lowercased().contains("login"),
                           banner: banner, open8081: open8081, tlsSubject: subject)
    }

    /// Connect to a port and read the greeting (printable, trimmed). Lutron LIP answers "login: ".
    nonisolated static func bannerProbe(_ host: String, port: UInt16, timeout: TimeInterval = 1.5) async -> (Bool, String) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return (false, "") }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let guardQ = DispatchQueue(label: "banner.guard")
            var resumed = false
            let finish: (Bool, String) -> Void = { open, banner in
                let first: Bool = guardQ.sync { if resumed { return false }; resumed = true; return true }
                guard first else { return }
                conn.cancel()
                cont.resume(returning: (open, banner))
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                        let raw = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        let printable = String(raw.filter { $0.isASCII && !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " ") })
                            .trimmingCharacters(in: .whitespaces)
                        finish(true, String(printable.prefix(60)))
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { finish(true, "") }
                case .failed, .waiting:
                    finish(false, "")
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2.5) { finish(false, "") }
        }
    }

    /// TLS-connect to a port and read the name on the certificate it presents.
    /// The certificate is accepted regardless (we only want to read it); nothing is sent.
    nonisolated static func tlsProbe(_ host: String, port: UInt16, timeout: TimeInterval = 1.5) async -> (Bool, String) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return (false, "") }
        return await withCheckedContinuation { cont in
            let guardQ = DispatchQueue(label: "tls.guard")
            var resumed = false
            var subject = ""
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first,
                   let summary = SecCertificateCopySubjectSummary(leaf) as String? {
                    guardQ.sync { subject = summary }
                }
                complete(true)
            }, guardQ)
            let params = NWParameters(tls: tls)
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
            let finish: (Bool) -> Void = { open in
                let first: Bool = guardQ.sync { if resumed { return false }; resumed = true; return true }
                guard first else { return }
                conn.cancel()
                let subj = guardQ.sync { subject }
                cont.resume(returning: (open, subj))
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2.0) {
                // Handshake did not complete in time; report whether TCP at least opened.
                finish(!guardQ.sync { subject }.isEmpty)
            }
        }
    }

    /// All host addresses of an a.b.c.0/24 (other prefix lengths fall back to /24 of the base).
    nonisolated static func expand(_ cidr: String) -> [String] {
        let base = cidr.split(separator: "/").first.map(String.init) ?? cidr
        var comps = base.split(separator: ".").map(String.init)
        guard comps.count == 4 else { return [] }
        return (1...254).map { comps[3] = String($0); return comps.joined(separator: ".") }
    }

    // MARK: - parsing (nonisolated: called from detached tasks)

    nonisolated static func parse(tool: String, text: String) -> [DiscoveredHost] {
        var out: [DiscoveredHost] = []
        let lines = text.components(separatedBy: .newlines)
        if tool == "arp-scan" {
            for line in lines {
                let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
                if cols.count >= 2, isIP(cols[0]), isMAC(cols[1]) {
                    out.append(host(cols[0], cols[1], cols.count > 2 ? cols[2...].joined(separator: " ") : ""))
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
                    var vendor = ""
                    if let vR = line.range(of: #"\((.*?)\)"#, options: .regularExpression) {
                        vendor = String(line[vR]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    }
                    out.append(host(ip, String(line[macR]), vendor))
                    currentIP = nil
                }
            }
        } else { // arp -a
            for line in lines {
                guard let ipR = line.range(of: #"(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression),
                      let macR = line.range(of: #"([0-9a-fA-F]{1,2}[:-]){5}[0-9a-fA-F]{1,2}"#, options: .regularExpression)
                else { continue }
                let mac = String(line[macR]).replacingOccurrences(of: "-", with: ":")
                if mac.lowercased().hasPrefix("ff:ff") { continue }
                out.append(host(String(line[ipR]), mac, ""))
            }
        }
        return out
    }

    nonisolated private static func host(_ ip: String, _ mac: String, _ vendorHint: String) -> DiscoveredHost {
        let vendor = vendorHint.isEmpty ? (OUI.isLocallyAdministered(mac) ? "private address (phone/laptop)" : (OUI.vendor(for: mac) ?? "")) : vendorHint
        return DiscoveredHost(ip: ip, mac: mac, vendor: vendor, classification: OUI.classify(mac: mac, vendorHint: vendorHint))
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
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.hasPrefix("169.254.") { address = ip; break }
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return address
    }
}

private func rank(_ h: DiscoveredHost) -> Int {
    if h.lipLogin || h.classification == "Lutron" || h.leapOpen { return 0 }
    switch h.classification {
    case "Savant": return 1
    case "Apple": return 2
    case "Denon/Marantz", "Sonos", "Hue": return 3
    case "Ubiquiti": return 4
    case "private": return 7
    case "unknown": return 6
    default: return 5
    }
}

private func ipKey(_ ip: String) -> [Int] { ip.split(separator: ".").compactMap { Int($0) } }
