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

    static func probe(host: String, port: Int, timeout: TimeInterval = 3) async -> (Bool, String) {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(rawValue: UInt16(port))!,
                                    using: .tcp)
            let guardQ = DispatchQueue(label: "portprobe.guard")
            var resumed = false
            let finish: (Bool, String) -> Void = { ok, detail in
                guardQ.sync {
                    if resumed { return }
                    resumed = true
                }
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

    static func identify(_ results: [PortResult]) -> (String, String) {
        let open = Set(results.filter { $0.open }.map { $0.port })
        if open.contains(8081) || open.contains(8083) {
            return ("LEAP", "8081/8083 open → HomeWorks QSX / RadioRA 3 / Caseta. Pair with the app (or pylutron-caseta).")
        }
        if open.contains(23) {
            return ("LIP", "23 open → HomeWorks QS / RadioRA 2 telnet. Try lutron/integration; confirm from the QNET>/GNET> prompt.")
        }
        return ("unknown", "No known Lutron integration port answered. Re-check the IP or integration may be disabled.")
    }
}
