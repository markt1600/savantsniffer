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

# --- MAC OUI prefixes (first 3 octets, uppercase, no separators) ---
# Lutron Electronics registered OUIs (first three octets). Matching also falls back
# to any vendor string containing "lutron", so an unlisted OUI is still caught by name.
LUTRON_OUIS = {"0016E1", "001BB1", "0007E0"}

# Apple OUIs are numerous; we match a representative common set and also fall back
# to any vendor string containing "Apple".
APPLE_OUIS = {
    "F0189E", "3C0754", "A45E60", "8C8590", "C82A14", "D0817A", "8C7C92",
    "A8BBCF", "F0DBF8", "AC87A3", "E0F847", "F86214", "40A6D9", "7CD1C3",
    "68967B", "D89E3F", "B8E856", "38C986", "88665A", "34363B",
}


def normalize_oui(mac: str) -> str:
    hexonly = re.sub(r"[^0-9A-Fa-f]", "", mac).upper()
    return hexonly[:6]


def guess_vendor(mac: str, vendor_hint: str = "") -> str:
    oui = normalize_oui(mac)
    if oui in LUTRON_OUIS or "lutron" in vendor_hint.lower():
        return "Lutron"
    if oui in APPLE_OUIS or "apple" in vendor_hint.lower():
        return "Apple"
    return vendor_hint or "unknown"


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
    buckets: dict[str, list[Host]] = {"Lutron": [], "Apple": [], "unknown": []}
    for h in hosts:
        buckets.setdefault(h.classification, []).append(h)
    return buckets
