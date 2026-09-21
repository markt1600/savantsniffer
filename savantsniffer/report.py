"""Integration report: everything discovered, with the exact commands another app
can send. The point is reuse — future apps read this instead of re-testing.

Markdown output; the live devices.yaml is the machine-readable twin.
"""
from __future__ import annotations
import datetime as _dt

from .devicemap import DeviceMap


def effective_button(bkey, btn: dict):
    """The real LIP button number.

    Two shapes coexist in devices.yaml: seed entries are keyed by engraving
    position and carry the real number in `button` (null until sniffed); entries
    written while labelling are keyed by the real number and have no `position`.
    """
    if btn.get("button") is not None:
        return btn["button"]
    if "position" not in btn:
        try:
            return int(bkey)
        except (TypeError, ValueError):
            return None
    return None


def button_status(btn: dict, keypad_id_known: bool, bkey=None) -> str:
    kind = btn.get("kind", "output")
    has = effective_button(bkey, btn) is not None
    if kind == "integration":
        if has and btn.get("savant_captured"):
            return "captured"
        if has:
            return "identified"
    elif kind == "macro":
        if has and btn.get("effect"):
            return "captured"
        if has:
            return "identified"
    else:
        if has:
            return "captured"
    return "identified" if keypad_id_known else "pending"


def _fmt(v) -> str:
    try:
        return f"{float(v):g}"
    except (TypeError, ValueError):
        return str(v)


def build_markdown(dmap: DeviceMap, env: dict | None = None) -> str:
    env = env or {}
    d = dmap.data
    host = d.get("processor") or env.get("LUTRON_HOST") or "unknown"
    user = env.get("LUTRON_LIP_USER", "lutron")
    pw = env.get("LUTRON_LIP_PASSWORD")
    o: list[str] = []
    o.append("# Lutron / Savant integration report")
    o.append("")
    o.append(f"Generated {_dt.datetime.now().isoformat(timespec='seconds')} by savantsniffer. "
             "**Contains credentials — keep it private.**")
    o.append("")
    o.append("## Connection")
    o.append("")
    o.append("| Item | Value |")
    o.append("|---|---|")
    o.append(f"| Lutron processor | `{host}` |")
    o.append(f"| System | {d.get('system') or 'unknown'} |")
    o.append("| Protocol | LIP over telnet, TCP port 23 |")
    o.append(f"| Login | user `{user}` / password `{pw or '(not stored)'}` |")
    o.append(f"| Savant host | `{d.get('savant_host') or env.get('SAVANT_HOST') or 'unknown'}` |")
    o.append("")
    o.append("## Protocol cheat sheet")
    o.append("")
    o.append("```")
    o.append(f"open TCP {host}:23")
    o.append(f'<- login:      -> send "{user}\\r\\n"')
    o.append(f'<- password:   -> send "{pw or "<password>"}\\r\\n"')
    o.append("<- QNET> / GNET>         (ready)")
    o.append("#MONITORING,3,1          enable keypad (~DEVICE) events")
    o.append("#MONITORING,5,1          enable load (~OUTPUT) events")
    o.append("?OUTPUT,<id>,1           query a load's level  -> ~OUTPUT,<id>,1,<level>")
    o.append("#OUTPUT,<id>,1,<level>   set a load 0-100")
    o.append("#OUTPUT,<id>,1,<level>,<fade-seconds>   set with a fade (e.g. 20,2)")
    o.append("#OUTPUT,<id>,2 / 3 / 4   raise / lower / stop (dim up-down buttons)")
    o.append("#DEVICE,<keypad>,<btn>,3 press a keypad button (4 = release)")
    o.append("```")
    o.append("")

    total = captured = identified = pending = 0
    body: list[str] = []
    pending_savant: list[str] = []
    for aname, adata in (d.get("areas") or {}).items():
        body.append(f"## {aname.title()}")
        body.append("")
        for kname, kdata in (adata.get("keypads") or {}).items():
            kid = kdata.get("id")
            kid_s = str(kid) if kid is not None else "?"
            body.append(f"### Keypad: {kname} (Lutron id {kid_s})")
            body.append("")
            body.append("| Button | Kind | # | Press command | Status | Effect / notes |")
            body.append("|---|---|---|---|---|---|")
            for bkey, b in (kdata.get("buttons") or {}).items():
                if not isinstance(b, dict):
                    b = {"label": str(b)}
                st = button_status(b, kid is not None, bkey)
                total += 1
                captured += st == "captured"; identified += st == "identified"; pending += st == "pending"
                num = effective_button(bkey, b)
                num_s = str(num) if num is not None else "?"
                cmd = f"`#DEVICE,{kid_s},{num_s},3`" if (kid is not None and num is not None) else "—"
                notes = []
                eff = b.get("effect") or []
                if eff:
                    notes.append(", ".join(f"{e.get('id')}→{_fmt(e.get('level'))}" for e in eff if isinstance(e, dict)))
                zones = b.get("audio_zones") or []
                if zones:
                    src = b.get("audio_source")
                    notes.append("audio zones: " + ", ".join(zones) + (f" from {src}" if src else ""))
                if b.get("kind") == "integration":
                    if b.get("savant_captured"):
                        notes.append("Savant: " + str(b.get("savant_note") or "captured"))
                    else:
                        notes.append("Savant side not captured")
                        pending_savant.append(f"{aname} · {kname} · {b.get('label', bkey)}")
                if b.get("intent"):
                    notes.append("intent: " + str(b["intent"]))
                body.append(f"| {b.get('label', bkey)} | {b.get('kind', 'output')} | {num_s} | {cmd} | {st} | {'; '.join(notes)} |")
            body.append("")
        outs = adata.get("outputs") or {}
        if outs:
            body.append("### Loads")
            body.append("")
            body.append("| Load | Lutron id | Kind | Set | Query |")
            body.append("|---|---|---|---|---|")
            for oname, od in outs.items():
                oid = od.get("id")
                body.append(f"| {oname} | {oid} | {od.get('kind', 'dimmer')} | `#OUTPUT,{oid},1,<0-100>` | `?OUTPUT,{oid},1` |")
            body.append("")

    o.append("## Coverage")
    o.append("")
    o.append(f"{captured} of {total} buttons fully captured, {identified} partial, {pending} pending.")
    o.append("")
    o.extend(body)

    macros = d.get("custom_macros") or []
    if macros:
        o.append("## Custom scenes")
        o.append("")
        for m in macros:
            o.append(f"### {m.get('name', 'scene')}")
            o.append("")
            o.append("```")
            for s in m.get("steps", []):
                o.append(str(s))
            o.append("```")
            o.append("")
    if pending_savant:
        o.append("## Integration buttons still needing Savant-side capture")
        o.append("")
        o.extend(f"- {p}" for p in pending_savant)
        o.append("")
    return "\n".join(o)
