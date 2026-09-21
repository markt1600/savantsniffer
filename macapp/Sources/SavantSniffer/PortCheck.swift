import Foundation
import Network
import Combine

@MainActor
final class PortCheckModel: ObservableObject {
    @Published var host: String = ""
    @Published var results: [PortResult] = []
    @Published var checking = false
    @Published var likelySystem: String = ""
    @Published var reasoning: String = ""

    private let ports = [23, 8081, 8083]

    func check() {
        guard !host.isEmpty else { return }
        checking = true; results = []; likelySystem = ""; reasoning = ""
        let host = self.host
        let ports = self.ports
        Task.detached {
            var found: [PortResult] = []
            for p in ports {
                let (open, detail) = await Self.probe(host: host, port: p)
                found.append(PortResult(port: p, open: open, detail: detail))
            }
            let (label, why) = Self.identify(found)
            await MainActor.run {
                self.results = found
                self.likelySystem = label
                self.reasoning = why
                self.checking = false
            }
        }
    }

    /// TCP-connect probe. The continuation is resumed exactly once: the first of
    /// ready / failed / waiting / timeout wins, the rest are ignored.
    nonisolated static func probe(host: String, port: Int, timeout: TimeInterval = 3) async -> (Bool, String) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: max(0, port))) else {
            return (false, "bad port")
        }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let guardQ = DispatchQueue(label: "portprobe.guard")
            var resumed = false
            let finish: (Bool, String) -> Void = { ok, detail in
                let first: Bool = guardQ.sync {
                    if resumed { return false }
                    resumed = true
                    return true
                }
                guard first else { return }
                conn.cancel()
                cont.resume(returning: (ok, detail))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true, "reachable")
                case .failed(let e): finish(false, "\(e)")
                case .waiting(let e): finish(false, "\(e)")
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false, "timeout")
            }
        }
    }

    nonisolated static func identify(_ results: [PortResult]) -> (String, String) {
        let open = Set(results.filter { $0.open }.map { $0.port })
        if open.contains(8081) || open.contains(8083) {
            return ("LEAP", "8081/8083 open → HomeWorks QSX / RadioRA 3 / Caseta. Pair with pylutron-caseta (see Credentials & LEAP).")
        }
        if open.contains(23) {
            return ("LIP", "23 open → HomeWorks QS / RadioRA 2 telnet. Try lutron/integration; the prompt (QNET>/GNET>) confirms which.")
        }
        return ("unknown", "No known Lutron integration port answered. Re-check the IP, or integration may be disabled.")
    }
}
