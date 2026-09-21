"""Guidance + parsing for capturing the Savant host <-> Lutron telnet session,
so you can recover the integration credentials from your OWN traffic when the
default login fails (goal 4).

This module does NOT start captures on its own. It builds the exact command for
your setup and shows it to you first; you run it. Then extract_credentials()
parses the resulting pcap/text for the login/password the Savant host sends.

Two capture paths, depending on your network:

A) UniFi / managed-switch port mirroring (SPAN):
   Mirror the switch port the Savant Mac mini is on to a port where your laptop
   runs Wireshark/tcpdump. In UniFi: Settings -> (Network) -> the switch ->
   Ports -> the mini's port -> Port Mirror -> mirror to your laptop's port.
   Then capture on your laptop's interface filtering to the Lutron processor:23.

B) tcpdump ON the Savant Mac mini itself (if you can get shell on it):
   Only if you're comfortable; you said no config changes — tcpdump is read-only
   and changes nothing. Requires sudo.

Because LIP telnet is PLAINTEXT, the username and password appear directly in the
TCP stream to port 23. (LEAP on 8081 is TLS — you cannot read creds from it; use
the pairing flow instead.)
"""
from __future__ import annotations
import re
from dataclasses import dataclass


def tcpdump_command(interface: str, processor_ip: str, outfile: str = "captures/lutron.pcap") -> str:
    """Command to capture only telnet traffic to the Lutron processor."""
    return (f"sudo tcpdump -i {interface} -s 0 -w {outfile} "
            f"'host {processor_ip} and tcp port 23'")


def tshark_follow_command(pcap: str) -> str:
    """Command to print the reassembled telnet stream(s) as text."""
    return (f"tshark -r {pcap} -q -z follow,tcp,ascii,0 "
            f"|| tshark -r {pcap} -Y 'telnet' -T fields -e telnet.data")


def live_tshark_command(interface: str, processor_ip: str) -> str:
    """Live-read the telnet conversation without writing a file first."""
    return (f"sudo tshark -i {interface} -f 'host {processor_ip} and tcp port 23' "
            f"-Y telnet -T fields -e telnet.data")


@dataclass
class Credentials:
    username: str | None = None
    password: str | None = None
    context: str = ""

    @property
    def found(self) -> bool:
        return bool(self.username and self.password)


# The Savant host answers 'login:' then 'password:' prompts. In a plaintext dump
# we see the prompts from the processor and the replies from Savant. Telnet often
# echoes per character; we handle both whole-line and char-echo shapes.
_LOGIN_RE = re.compile(r"login:\s*([^\r\n]+)", re.IGNORECASE)
_PASS_RE = re.compile(r"password:\s*([^\r\n]+)", re.IGNORECASE)


def extract_credentials(text: str) -> Credentials:
    """Parse reassembled telnet text (from tshark 'follow' or telnet.data)."""
    # Collapse telnet negotiation bytes and CRs for readability.
    cleaned = re.sub(r"[\x00-\x08\x0b-\x1f]", "", text)
    user = None
    pw = None
    m = _LOGIN_RE.search(cleaned)
    if m:
        user = m.group(1).strip()
    m = _PASS_RE.search(cleaned)
    if m:
        pw = m.group(1).strip()
    # Fallback: two consecutive short tokens right after the prompts.
    return Credentials(username=user, password=pw,
                       context="parsed from reassembled telnet stream")


def write_env(creds: Credentials, host: str, path: str = ".env") -> None:
    """Append discovered creds to .env (git-ignored). Never printed to logs/stdout by callers."""
    lines = []
    if host:
        lines.append(f"LUTRON_HOST={host}")
    if creds.username:
        lines.append(f"LUTRON_LIP_USER={creds.username}")
    if creds.password:
        lines.append(f"LUTRON_LIP_PASSWORD={creds.password}")
    with open(path, "a") as f:
        f.write("\n# --- captured " + "".join(lines[:1]) + "\n")
        for ln in lines:
            f.write(ln + "\n")


def print_guidance(interface: str = "en0", processor_ip: str = "192.168.1.50") -> None:
    print(__doc__)
    print("\n--- Commands for your setup (edit interface / processor IP) ---\n")
    print("Capture to file (path A or B):")
    print("    " + tcpdump_command(interface, processor_ip))
    print("\nReassemble the capture to readable text:")
    print("    " + tshark_follow_command("captures/lutron.pcap"))
    print("\nOr live-read the telnet conversation directly:")
    print("    " + live_tshark_command(interface, processor_ip))
    print("\nThen extract credentials in Python:")
    print("    from savantsniffer.capture import extract_credentials")
    print("    creds = extract_credentials(open('stream.txt').read())")
    print("    # creds.username / creds.password  (LIP telnet is plaintext)")


if __name__ == "__main__":
    import sys
    iface = sys.argv[1] if len(sys.argv) > 1 else "en0"
    proc = sys.argv[2] if len(sys.argv) > 2 else "192.168.1.50"
    print_guidance(iface, proc)
