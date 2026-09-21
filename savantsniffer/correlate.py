"""Correlate keypad presses with what the Savant host sent right after them.

Lutron only reports the keypad press. Savant listens to that same event feed and
then talks to the audio/AV hardware. To learn which zones a button drives, we line
up each ~DEVICE press (from the monitor log) with the packets the Savant host sent
in the next couple of seconds (from a tshark field export).

Produce the packet file with:
  tshark -r savant.pcap -Y 'ip.src==<savant-ip>' -T fields -E separator=/t \\
    -e frame.time_epoch -e ip.dst -e tcp.dstport -e udp.dstport -e tcp.payload -e udp.payload > savant.txt
"""
from __future__ import annotations
import datetime as _dt
import re
from collections import defaultdict
from dataclasses import dataclass, field


@dataclass
class Packet:
    t: float            # epoch seconds
    dst: str
    port: int
    proto: str          # tcp | udp
    payload: bytes

    def preview(self, n: int = 60) -> str:
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in self.payload[:n])
        return text + ("…" if len(self.payload) > n else "")


@dataclass
class Press:
    t: float
    raw: str
    keypad: int
    button: int


@dataclass
class Match:
    press: Press
    targets: list[dict] = field(default_factory=list)   # {dst, port, proto, count, preview}


def _hex_to_bytes(h: str) -> bytes:
    h = h.strip().replace(":", "")
    if not h:
        return b""
    try:
        return bytes.fromhex(h)
    except ValueError:
        return b""


def parse_savant_fields(text: str) -> list[Packet]:
    out: list[Packet] = []
    for line in text.splitlines():
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 6:
            continue
        try:
            t = float(cols[0])
        except ValueError:
            continue
        dst = cols[1]
        if cols[2]:
            out.append(Packet(t, dst, int(cols[2]), "tcp", _hex_to_bytes(cols[4])))
        elif cols[3]:
            out.append(Packet(t, dst, int(cols[3]), "udp", _hex_to_bytes(cols[5])))
    return out


_ISO = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(.*)$")
_TIME = re.compile(r"^(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(.*)$")


def parse_monitor_log(text: str, date_hint: _dt.date | None = None) -> list[Press]:
    """Accepts the Python log (ISO timestamp) and the Mac app log (HH:MM:SS.mmm)."""
    out: list[Press] = []
    for line in text.splitlines():
        m = _ISO.match(line)
        if m:
            ts = _dt.datetime.fromisoformat(m.group(1))
            raw = m.group(2).strip()
        else:
            m = _TIME.match(line)
            if not m:
                continue
            base = date_hint or _dt.date.today()
            ts = _dt.datetime.combine(base, _dt.time.fromisoformat(m.group(1)))
            raw = m.group(2).strip()
        if not raw.startswith("~DEVICE"):
            continue
        parts = raw.split(",")
        if len(parts) < 4:
            continue
        try:
            keypad, button, action = int(parts[1]), int(parts[2]), int(parts[3])
        except ValueError:
            continue
        if action != 3:          # 3 = press
            continue
        out.append(Press(ts.timestamp(), raw, keypad, button))
    return out


def correlate(presses: list[Press], packets: list[Packet], window: float = 2.0) -> list[Match]:
    packets = sorted(packets, key=lambda p: p.t)
    results: list[Match] = []
    for pr in presses:
        groups: dict[tuple, dict] = defaultdict(lambda: {"count": 0, "preview": ""})
        for pk in packets:
            if pk.t < pr.t:
                continue
            if pk.t > pr.t + window:
                break
            g = groups[(pk.dst, pk.port, pk.proto)]
            g["count"] += 1
            if not g["preview"] and pk.payload:
                g["preview"] = pk.preview()
        m = Match(press=pr)
        for (dst, port, proto), g in sorted(groups.items(), key=lambda kv: -kv[1]["count"]):
            m.targets.append({"dst": dst, "port": port, "proto": proto,
                              "count": g["count"], "preview": g["preview"]})
        results.append(m)
    return results


def render(results: list[Match], window: float) -> str:
    o = ["# Press → Savant traffic correlation", "",
         f"Window: {window:g}s after each keypad press. One section per press; targets sorted by packet count.", ""]
    for m in results:
        when = _dt.datetime.fromtimestamp(m.press.t).strftime("%H:%M:%S.%f")[:-3]
        o.append(f"## {when}  keypad {m.press.keypad} button {m.press.button}  (`{m.press.raw}`)")
        o.append("")
        if not m.targets:
            o.append("_no Savant traffic in window — probably a Lutron-only button_")
        else:
            o.append("| Target | Proto | Packets | First payload |")
            o.append("|---|---|---|---|")
            for t in m.targets:
                o.append(f"| {t['dst']}:{t['port']} | {t['proto']} | {t['count']} | `{t['preview']}` |")
        o.append("")
    o.append("Next: note which audio zones actually came on for each press, then record them on the button "
             "(web UI label, or the Mac app's capture sheet). Plain-TCP payloads shown above can be replayed "
             "as Savant steps in a custom scene.")
    return "\n".join(o)
