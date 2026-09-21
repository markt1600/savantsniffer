"""Detect the host OS and report which discovery/capture tools are available.

We never install anything automatically. This module only *reports* what exists
so the caller can tell the user before suggesting an install.
"""
from __future__ import annotations
import platform
import shutil
from dataclasses import dataclass, field


@dataclass
class ToolStatus:
    name: str
    present: bool
    path: str | None = None
    install_hint: str = ""


@dataclass
class OSInfo:
    system: str          # 'Darwin', 'Linux', 'Windows'
    pretty: str          # human label
    tools: dict[str, ToolStatus] = field(default_factory=dict)

    def have(self, name: str) -> bool:
        t = self.tools.get(name)
        return bool(t and t.present)


# Per-OS install hints (shown to the user, never auto-run).
_HINTS = {
    "Darwin": {
        "nmap": "brew install nmap",
        "arp-scan": "brew install arp-scan   # run with sudo",
        "tcpdump": "preinstalled on macOS",
        "arp": "preinstalled on macOS",
        "ifconfig": "preinstalled on macOS",
    },
    "Linux": {
        "nmap": "sudo apt install nmap   (or dnf/pacman equivalent)",
        "arp-scan": "sudo apt install arp-scan",
        "tcpdump": "sudo apt install tcpdump",
        "arp": "usually in net-tools: sudo apt install net-tools",
        "ip": "preinstalled (iproute2)",
    },
    "Windows": {
        "nmap": "Install Npcap + Nmap from nmap.org",
        "arp": "preinstalled (arp -a)",
        "tshark": "Install Wireshark (includes tshark/dumpcap)",
    },
}


def detect() -> OSInfo:
    system = platform.system()
    pretty = f"{platform.system()} {platform.release()} ({platform.machine()})"
    hints = _HINTS.get(system, {})
    candidates = ["nmap", "arp-scan", "arp", "tcpdump", "tshark", "ip", "ifconfig", "python3"]
    tools: dict[str, ToolStatus] = {}
    for name in candidates:
        path = shutil.which(name)
        tools[name] = ToolStatus(
            name=name,
            present=path is not None,
            path=path,
            install_hint=hints.get(name, ""),
        )
    return OSInfo(system=system, pretty=pretty, tools=tools)


def preferred_scanner(info: OSInfo | None = None) -> str | None:
    """Return the best available discovery tool for this OS, or None."""
    info = info or detect()
    for name in ("arp-scan", "nmap"):
        if info.have(name):
            return name
    if info.system == "Windows" and info.have("arp"):
        return "arp"
    return "arp" if info.have("arp") else None


if __name__ == "__main__":
    i = detect()
    print(f"OS: {i.pretty}")
    for t in i.tools.values():
        mark = "OK " if t.present else "-- "
        line = f"  [{mark}] {t.name}"
        if not t.present and t.install_hint:
            line += f"   (install: {t.install_hint})"
        print(line)
    print(f"\nPreferred discovery tool: {preferred_scanner(i) or 'none found'}")
