"""Port-check a Lutron processor and guess which system it is.

Ports of interest:
  23   telnet  -> Lutron Integration Protocol (LIP). HomeWorks QS / RadioRA 2.
  8081 TLS     -> LEAP. HomeWorks QSX / RadioRA 3 / Caseta (pylutron-caseta).
  8083 TLS/HTTPS -> LEAP web / secondary (often present alongside 8081 on QSX).

This only opens TCP sockets to check reachability. It sends nothing to the
device beyond the TCP handshake, so it does not touch programming or state.
"""
from __future__ import annotations
import socket
import ssl
from dataclasses import dataclass, field

PORTS = {
    23: "telnet / LIP (HomeWorks QS, RadioRA 2)",
    8081: "LEAP over TLS (HomeWorks QSX, RadioRA 3, Caseta)",
    8083: "LEAP web / secondary (often QSX)",
}


@dataclass
class PortResult:
    port: int
    open: bool
    tls: bool = False
    detail: str = ""


@dataclass
class ProbeReport:
    host: str
    results: list[PortResult] = field(default_factory=list)

    @property
    def open_ports(self) -> list[int]:
        return [r.port for r in self.results if r.open]

    def likely_system(self) -> tuple[str, str]:
        """Return (label, reasoning)."""
        openp = set(self.open_ports)
        if 8081 in openp or 8083 in openp:
            return ("LEAP", "Port 8081/8083 open -> HomeWorks QSX / RadioRA 3 / Caseta. "
                            "Use pylutron-caseta with button pairing.")
        if 23 in openp:
            return ("LIP", "Port 23 open -> HomeWorks QS / RadioRA 2 telnet integration. "
                           "Try default login lutron/integration; confirm from the QNET>/GNET> prompt.")
        return ("unknown", "No known Lutron integration port answered. "
                           "Double-check the IP, or the processor may have integration disabled.")


def check_port(host: str, port: int, timeout: float = 3.0) -> PortResult:
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            tls = False
            detail = ""
            if port in (8081, 8083):
                ctx = ssl._create_unverified_context()  # Lutron uses a self-signed device cert
                try:
                    with ctx.wrap_socket(sock, server_hostname=host) as ss:
                        tls = True
                        cert = ss.getpeercert(binary_form=True)
                        detail = f"TLS handshake OK ({len(cert)} byte cert)" if cert else "TLS OK"
                except ssl.SSLError as e:
                    detail = f"open, TLS negotiation issue: {e}"
            return PortResult(port=port, open=True, tls=tls, detail=detail)
    except (socket.timeout, ConnectionRefusedError, OSError) as e:
        return PortResult(port=port, open=False, detail=str(e))


def probe(host: str, ports: list[int] | None = None, timeout: float = 3.0) -> ProbeReport:
    ports = ports or list(PORTS.keys())
    return ProbeReport(host=host, results=[check_port(host, p, timeout) for p in ports])


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("usage: python -m savantsniffer.portcheck <host>")
        raise SystemExit(2)
    rep = probe(sys.argv[1])
    for r in rep.results:
        state = "OPEN" if r.open else "closed"
        print(f"  {r.port:>5}  {state:<6} {PORTS.get(r.port,'')}  {r.detail}")
    label, why = rep.likely_system()
    print(f"\nLikely system: {label}\n  {why}")
