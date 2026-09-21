"""LAN discovery: find the Lutron processor and the Savant Mac mini.

Design rules honored here:
  * Detect OS first; only use tools that exist.
  * NEVER run a scan implicitly. build_scan_command() returns the exact command
    string so the caller can show it to the user for approval BEFORE running.
  * Scan only the local subnet (auto-detected, or provided).
"""
from __future__ import annotations
import ipaddress
import re
import socket
import subprocess
from dataclasses import dataclass, field

from .osdetect import OSInfo, detect, preferred_scanner

# --- MAC vendor lookup: the full IEEE MA-L registry ships with the package ---
_OUI_TABLE: dict[str, str] | None = None


def _oui_table() -> dict[str, str]:
    global _OUI_TABLE
    if _OUI_TABLE is None:
        import importlib.resources as res
        table: dict[str, str] = {}
        try:
            text = res.files("savantsniffer").joinpath("data/oui.tsv").read_text(encoding="utf-8")
            for line in text.splitlines():
                k, _, v = line.partition("\t")
                if k and v:
                    table[k] = v
        except (FileNotFoundError, OSError):
            pass
        _OUI_TABLE = table
    return _OUI_TABLE


def normalize_oui(mac: str) -> str:
    """First three octets, zero-padded (macOS `arp -a` prints "0:f:e7:…")."""
    parts = re.split(r"[:-]", mac.strip())
    if len(parts) >= 3:
        return "".join(p.upper().zfill(2) for p in parts[:3])
    hexonly = re.sub(r"[^0-9A-Fa-f]", "", mac).upper()
    return hexonly[:6]


def is_locally_administered(mac: str) -> bool:
    """Randomised private Wi-Fi addresses (phones/laptops) set bit 1 of octet 0."""
    oui = normalize_oui(mac)
    try:
        return bool(int(oui[:2], 16) & 0x02)
    except ValueError:
        return False


def vendor_name(mac: str) -> str:
    return _oui_table().get(normalize_oui(mac), "")


def guess_vendor(mac: str, vendor_hint: str = "") -> str:
    """Coarse class: Lutron | Savant | Apple | private | <vendor name> | unknown."""
    if not vendor_hint and is_locally_administered(mac):
        return "private"
    name = (vendor_hint or vendor_name(mac)).lower()
    if "lutron" in name:
        return "Lutron"
    if "savant" in name:
        return "Savant"
    if "apple" in name:
        return "Apple"
    return (vendor_hint or vendor_name(mac)) or "unknown"


@dataclass
class Host:
    ip: str
    mac: str = ""
    vendor: str = ""

    @property
    def classification(self) -> str:
        return guess_vendor(self.mac, self.vendor)


@dataclass
class ScanPlan:
    tool: str
    command: list[str]
    needs_sudo: bool
    subnet: str
    note: str = ""

    @property
    def shown(self) -> str:
        prefix = "sudo " if self.needs_sudo else ""
        return prefix + " ".join(self.command)


def local_subnet() -> str | None:
    """Best-effort local /24 detection without scanning anything."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))  # no packets actually sent for UDP connect
        ip = s.getsockname()[0]
        s.close()
        net = ipaddress.ip_network(f"{ip}/24", strict=False)
        return str(net)
    except OSError:
        return None


def build_scan_command(subnet: str | None = None, info: OSInfo | None = None) -> ScanPlan:
    """Return the exact scan command to SHOW the user. Does not run it."""
    info = info or detect()
    subnet = subnet or local_subnet() or "192.168.1.0/24"
    tool = preferred_scanner(info)

    if tool == "arp-scan":
        return ScanPlan(
            tool="arp-scan",
            command=["arp-scan", subnet],
            needs_sudo=True,
            subnet=subnet,
            note="Fast layer-2 scan; returns IP + MAC + vendor directly.",
        )
    if tool == "nmap":
        return ScanPlan(
            tool="nmap",
            command=["nmap", "-sn", subnet],
            needs_sudo=(info.system != "Windows"),
            subnet=subnet,
            note="Ping sweep. Run as root to populate MAC addresses via ARP.",
        )
    # Fallback: passive ARP cache read (no active scanning).
    if info.system == "Windows":
        return ScanPlan(tool="arp", command=["arp", "-a"], needs_sudo=False, subnet=subnet,
                        note="Reads the existing ARP cache only (no active scan).")
    return ScanPlan(tool="arp", command=["arp", "-a"], needs_sudo=False, subnet=subnet,
                    note="Reads the existing ARP cache only (no active scan).")


# --- Parsers for each tool's output ---
_ARP_SCAN_RE = re.compile(r"^(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F:]{17})\s+(.*)$")
_ARP_A_RE = re.compile(r"\(?(\d+\.\d+\.\d+\.\d+)\)?\s+.*?([0-9a-fA-F:-]{17})")
_NMAP_IP_RE = re.compile(r"Nmap scan report for (?:.*?\()?(\d+\.\d+\.\d+\.\d+)")
_NMAP_MAC_RE = re.compile(r"MAC Address: ([0-9A-Fa-f:]{17}) \((.*?)\)")


def parse_scan_output(tool: str, text: str) -> list[Host]:
    hosts: list[Host] = []
    if tool == "arp-scan":
        for line in text.splitlines():
            m = _ARP_SCAN_RE.match(line.strip())
            if m:
                hosts.append(Host(ip=m.group(1), mac=m.group(2), vendor=m.group(3).strip()))
    elif tool == "nmap":
        cur: Host | None = None
        for line in text.splitlines():
            ipm = _NMAP_IP_RE.search(line)
            if ipm:
                cur = Host(ip=ipm.group(1))
                hosts.append(cur)
                continue
            macm = _NMAP_MAC_RE.search(line)
            if macm and cur is not None:
                cur.mac = macm.group(1)
                cur.vendor = macm.group(2)
    else:  # arp -a
        for line in text.splitlines():
            m = _ARP_A_RE.search(line)
            if m:
                hosts.append(Host(ip=m.group(1), mac=m.group(2).replace("-", ":")))
    return hosts


def run_scan(plan: ScanPlan, timeout: int = 120, sudo: bool = True) -> tuple[list[Host], str]:
    """Run an APPROVED scan plan. Caller is responsible for having shown/confirmed it.

    sudo=False runs the tool unprivileged (for non-interactive callers such as the
    web UI, where sudo has no terminal to prompt on). MAC addresses may then be
    missing from nmap output; arp-scan needs root and will fail.
    """
    cmd = (["sudo"] if (plan.needs_sudo and sudo) else []) + plan.command
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    out = proc.stdout + ("\n" + proc.stderr if proc.stderr else "")
    return parse_scan_output(plan.tool, out), out


def classify_hosts(hosts: list[Host]) -> dict[str, list[Host]]:
    buckets: dict[str, list[Host]] = {"Lutron": [], "Savant": [], "Apple": [], "other": [], "private": [], "unknown": []}
    for h in hosts:
        c = h.classification
        key = c if c in ("Lutron", "Savant", "Apple", "private", "unknown") else "other"
        buckets[key].append(h)
    return buckets
