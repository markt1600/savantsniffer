"""Import a Savant host's own configuration into the device map.

Point this at a copy of the Savant host's RacePointMedia folder (or at a
subset of it). Nothing is sent anywhere; the files are read, never written.

What is read and what it yields:

  userConfig.rpmConfig/LiteInterfaceConfiguration.plist
      Savant Lighting's view of the Lutron system: every load (LEAP /zone href,
      name, room, dimmer or relay), every shade group, and every Lutron keypad
      button Savant was given (LEAP /button href, its LED href, label, room).
  userConfig.rpmConfig/workflows/<room>/<service>/<name>.workflow
      What Savant does when a button fires something outside Lutron: audio zone
      power/volume, a Spotify preset on the media server, a Savant scene, HVAC.
  userConfig.rpmConfig/userConnection.xml
      IP control settings of every AV device (address, port) and the audio
      wiring: which amplifier output feeds which room's speakers.
  userConfig.rpmConfig/zoneConfig.xml
      Which devices live in which room.
  lighting/shm/loadgroups.out, lighting/shm/sdo/OLAConfig/*, lighting/shm/sdo/NetworkDevice/*,
  statusfiles/controllers/*
      Current load levels, Lutron area names, the Savant LEAP bridge's address
      and the MAC address of the Lutron processor it talks to.

The result is a map in the devices.yaml schema (areas -> outputs/keypads/buttons)
plus a findings dict (bridge, processor, AV devices, audio zones, workflows)
that the report prints. Button -> workflow links are inferred by name within a
room and are flagged as such; the exact binding lives in Savant's scene
database, which is not part of the export.
"""
from __future__ import annotations

import glob
import json
import os
import plistlib
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

# ------------------------------------------------------------------ locating

NEEDLES = {
    "lite": "LiteInterfaceConfiguration.plist",
    "userconn": "userConnection.xml",
    "zonecfg": "zoneConfig.xml",
    "loadgroups": "loadgroups.out",
    "servicecmds": "serviceCommands",
    "sysinfo": "rpmSystemInfo.plist",
}


def find_files(root: str, max_depth: int = 6) -> dict:
    """Locate the interesting files anywhere under root (depth-limited walk)."""
    found: dict = {"workflows": [], "olaconfig": [], "networkdevice": [], "controllers": []}
    root = os.path.abspath(root)
    base_depth = root.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root):
        depth = dirpath.count(os.sep) - base_depth
        if depth >= max_depth:
            dirnames[:] = []
        # never descend into huge irrelevant trees
        dirnames[:] = [d for d in dirnames if d not in ("www", "Plugins", "tftpboot", "UpgradeInfo", "Music", "ArtworkCache")]
        parent = os.path.basename(dirpath)
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            for key, needle in NEEDLES.items():
                if fn == needle and key not in found:
                    # prefer the deployed bundle over dealer backups
                    found[key] = p
            if fn == "document.wflow":
                found["workflows"].append(p)
            elif parent == "OLAConfig":
                found["olaconfig"].append(p)
            elif parent == "NetworkDevice":
                found["networkdevice"].append(p)
            elif parent == "controllers":
                found["controllers"].append(p)
    # if several bundles exist, prefer the one called userConfig.rpmConfig
    for key in ("lite", "userconn", "zonecfg"):
        if key in found and "userConfig.rpmConfig" not in found[key]:
            alt = [p for p in glob.glob(os.path.join(root, "**", "userConfig.rpmConfig", NEEDLES[key]), recursive=True)]
            if alt:
                found[key] = alt[0]
    found["workflows"] = [p for p in found["workflows"] if "userConfig.rpmConfig" in p] or found["workflows"]
    return found


def _load_plist(path: str):
    with open(path, "rb") as f:
        return plistlib.load(f)


def _load_json_or_plist(path: str):
    with open(path, "rb") as f:
        b = f.read()
    try:
        return json.loads(b)
    except Exception:
        return plistlib.loads(b)


def _href_num(href: str | None) -> int | None:
    if not href:
        return None
    m = re.search(r"(\d+)$", href)
    return int(m.group(1)) if m else None


def _clean(label: str) -> str:
    return re.sub(r"\s+", " ", (label or "").replace("\n", " ")).strip()


# ------------------------------------------------------------------ model

@dataclass
class Findings:
    source_root: str = ""
    system_name: str = ""
    bridge_ip: str = ""
    bridge_mac: str = ""
    bridge_uid: str = ""
    processor_mac: str = ""
    lutron_areas: dict = field(default_factory=dict)      # savant room -> [/area/..]
    devices: list = field(default_factory=list)           # [{name, ip, port, room, kind, protocol}]
    audio_zones: dict = field(default_factory=dict)       # "Output Module:Audio Zone 3" -> room
    workflows: list = field(default_factory=list)         # [{room, service, name, actions:[str]}]
    load_levels: dict = field(default_factory=dict)       # load name -> current %
    counts: dict = field(default_factory=dict)
    notes: list = field(default_factory=list)

    def as_dict(self) -> dict:
        return {k: getattr(self, k) for k in self.__dataclass_fields__}


# ------------------------------------------------------------------ parsers

def parse_lighting(path: str) -> dict:
    """LiteInterfaceConfiguration.plist -> loads, shades, buttons, areas."""
    d = _load_plist(path)
    ctrls = d.get("Controllers") or {}
    out = {"loads": [], "shades": [], "buttons": [], "areas": {}, "controller_name": ""}
    for cname, c in ctrls.items():
        out["controller_name"] = cname
        for kp in c.get("Keypads") or []:
            out["areas"].update(kp.get("Areas") or {})
            out["bridge_uid"] = kp.get("UID", "")
            out["bridge_name"] = kp.get("KeypadName", "")
            for l in kp.get("Loads") or []:
                out["loads"].append({
                    "name": l.get("LoadName", ""), "room": l.get("LoadZone") or "",
                    "href": l.get("Href", ""), "subtype": l.get("LoadSubType", ""),
                    "manufacturer": l.get("LoadManufacture", ""), "load_id": l.get("LoadID", ""),
                    "min": l.get("LoadMin", 0), "max": l.get("LoadMax", 100),
                })
            for s in kp.get("Shades") or []:
                out["shades"].append({
                    "name": s.get("LoadName", ""), "room": s.get("LoadZone") or "",
                    "href": s.get("Href", ""), "load_id": s.get("LoadID", ""),
                })
            for b in kp.get("Scenes") or []:       # Savant calls Lutron buttons "Scenes"
                out["buttons"].append({
                    "label": _clean(b.get("DeviceLabel", "")), "room": b.get("SavantZone") or "",
                    "href": b.get("Href", ""), "led": b.get("LEDref", ""),
                    "uid": b.get("DeviceUID", ""), "offset": b.get("Offset", ""),
                    "type": b.get("ButtonType", ""),
                })
    return out


def parse_workflows(paths: list[str]) -> list[dict]:
    """Automator-style Savant workflows -> [{room, service, name, actions}]."""
    out = []
    for p in sorted(paths):
        parts = p.split(os.sep)
        try:
            room, service, wf = parts[-5], parts[-4], parts[-3].replace(".workflow", "")
        except IndexError:
            continue
        try:
            doc = _load_plist(p)
        except Exception:
            continue
        actions = []
        for a in doc.get("actions") or []:
            act = a.get("action", a)
            prm = act.get("ActionParameters") or {}
            name = act.get("ActionName") or act.get("AMActionName") or ""
            cls = prm.get("RPMClassName", "")
            if cls == "avAction":
                comp = prm.get("componentID", "")
                logical = prm.get("logicalComponentName", "")
                cmd = prm.get("actionName", "")
                args = prm.get("arguments") or []
                argtxt = ""
                for arg in args if isinstance(args, list) else []:
                    v = str(arg.get("argValue", ""))
                    if arg.get("argName") == "GUID" and v.startswith("connect:preset:"):
                        argtxt = " (Spotify preset)"
                    elif v and arg.get("argName") in ("Address1", "ThermostatAddress"):
                        argtxt += f" {arg.get('argName')}={v}"
                actions.append({"kind": "device", "component": comp, "logical": logical,
                                "command": cmd, "text": f"{comp} / {logical}: {cmd}{argtxt}"})
            elif cls == "svcCallServiceAction":
                scene = ""
                for arg in prm.get("arguments") or []:
                    if arg.get("name") == "SceneName":
                        scene = arg.get("value", "")
                ev = prm.get("selectedEvent", "")
                actions.append({"kind": "service", "component": "", "logical": "", "command": ev,
                                "scene": scene, "zone": prm.get("selectedZone", ""),
                                "text": f"{ev} '{scene}' in {prm.get('selectedZone', '')}" if scene else f"{ev} ({prm.get('selectedService', '')})"})
            elif cls == "rpmStateSetAction":
                actions.append({"kind": "state", "component": "", "logical": "", "command": "set state",
                                "text": f"set state {prm.get('stateName', '')} = {prm.get('stateValue', '')}"})
            elif name == "Run Shell Script":
                cmd = (prm.get("COMMAND_STRING") or "").strip()
                if cmd:
                    actions.append({"kind": "shell", "component": "", "logical": "", "command": "shell",
                                    "text": "shell: " + cmd[:160]})
        out.append({"room": room, "service": service.split("-")[-1], "name": wf, "actions": actions})
    return out


def parse_user_connection(path: str) -> tuple[list[dict], dict]:
    """userConnection.xml -> (devices with IP control, audio zone wiring)."""
    root = ET.parse(path).getroot()
    devices, wiring = [], {}
    for comp in root.findall("component"):
        name = comp.get("user_defined_name") or ""
        for ipc in comp.iter("ip_control"):
            addr = ipc.get("address") or ""
            creds = ""
            if "@" in addr:
                creds, addr = addr.rsplit("@", 1)
            port = ipc.get("port") or ""
            devices.append({"name": name, "ip": addr, "port": port, "credentials": creds,
                            "protocol": _protocol_hint(name, port), "room": ""})
        for irc in comp.iter("ir_control"):
            mp = irc.find("master_controller_port")
            devices.append({"name": name, "ip": "", "port": "IR",
                            "credentials": "", "room": "",
                            "protocol": f"IR via {mp.get('master_name')} {mp.get('name')}" if mp is not None else "IR"})
        for outp in comp.findall("output"):
            if outp.find("audio_media") is None:
                continue
            oname = outp.get("name_on_component") or ""
            for peer in outp.iter("peer_io"):
                target = peer.get("user_defined_name") or ""
                if "Speaker" in target or "Beolab" in target:
                    wiring[f"{name} :: {oname}"] = target
    # de-duplicate (one entry per name+port)
    seen, uniq = set(), []
    for d in devices:
        k = (d["name"], d["ip"], d["port"])
        if k not in seen:
            seen.add(k); uniq.append(d)
    return uniq, wiring


def _protocol_hint(name: str, port: str) -> str:
    n = name.lower()
    if port == "23":
        return "telnet (plain text; capturable)"
    if port == "10102":
        return "CoolAutomation CoolLink TCP (plain text)"
    if port == "80":
        return "HTTP (Bond / Hue / camera APIs)"
    if port == "443":
        return "HTTPS"
    if port == "31415":
        return "Big Ass Fans SenseME UDP/TCP"
    if port == "20554":
        return "JVC projector IP control"
    if port == "0" and "atv" in n:
        return "Apple TV (HomeKit / Companion)"
    return ""


def parse_zone_config(path: str) -> dict:
    """zoneConfig.xml -> device name -> room."""
    root = ET.parse(path).getroot()
    rooms = {}
    for zone in root.findall("zone"):
        for c in zone.iter("component"):
            n = c.get("user_defined_name")
            if n and n not in rooms:
                rooms[n] = zone.get("name") or ""
    return rooms


def parse_loadgroups(path: str) -> dict:
    """lighting/shm/loadgroups.out -> load name -> current level (%), from the single-load scenes."""
    txt = open(path, errors="replace").read()
    levels = {}
    for m in re.finditer(r"^Scene (.+?) Scene: Offset\(\d+\).*?\n\tPreset (\d+)%, Current (\d+)%\n\t([0-9A-F]+),", txt, re.M):
        levels[m.group(1)] = int(m.group(3))
    return levels


def parse_ola(paths: list[str]) -> dict:
    """OLAConfig -> zone href -> Lutron area name(s)."""
    out = {}
    for p in paths:
        try:
            d = _load_json_or_plist(p)
        except Exception:
            continue
        for e in (d or {}).values():
            zm = e.get("ZoneMapping") or {}
            if e.get("Href"):
                out[e["Href"]] = ", ".join(zm.get("LutronAreas") or [])
    return out


def parse_network_device(paths: list[str]) -> tuple[str, str]:
    for p in paths:
        try:
            d = _load_json_or_plist(p)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("ip"):
            return d.get("ip", ""), d.get("uid", "")
    return "", ""


def parse_controllers(paths: list[str]) -> str:
    for p in paths:
        try:
            d = _load_json_or_plist(p)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("controllerMacAddr"):
            return d["controllerMacAddr"]
    return ""


def mac_from_uid(uid: str) -> str:
    """Savant lighting UIDs are the device MAC followed by a product id: 985DAD7CC081 0042."""
    if len(uid) >= 12 and re.fullmatch(r"[0-9A-Fa-f]+", uid):
        h = uid[:12].lower()
        return ":".join(h[i:i + 2] for i in range(0, 12, 2))
    return ""


# ------------------------------------------------------------------ inference

def classify_button(label: str) -> tuple[str, str]:
    """-> (kind, intent) from the button's label."""
    l = label.lower()
    if any(w in l for w in ("music", "vol up", "vol down", "broadcast", "movie", "spotify")):
        return "integration", "Savant: audio / media"
    if any(w in l for w in ("ac", "dehumidify", "room ac", "hallway ac", "home ac")) and l.split()[-1] in ("ac", "dehumidify"):
        return "hvac", "Savant: HVAC"
    if "curtain" in l or "shade" in l or l in ("open", "close"):
        return "shade", "Lutron shade group"
    if "fan" in l:
        return "fan", "Lutron relay (fan)"
    if any(w in l for w in ("off", "ambient", "relaxed", "focused", "evening", "morning", "night light", "home light", "color")):
        return "macro", "Lutron scene (several loads)"
    return "output", "Lutron load"


_WF_STRIP = re.compile(r"\s*\((.*?)\)\s*$")


def _wf_key(name: str) -> str:
    n = _WF_STRIP.sub("", name).lower().strip()
    for suf in (" on scene", " off scene", " scene", " on", " enable", " disable"):
        if n.endswith(suf):
            n = n[: -len(suf)].strip()
    return n


def _btn_key(label: str) -> str:
    l = label.lower().strip()
    l = l.replace("vol up", "vol up").replace("vol down", "vol down")
    return l


def link_buttons_to_workflows(buttons: list[dict], workflows: list[dict]) -> None:
    """Attach workflow summaries to buttons by room + name. Marked inferred."""
    by_room: dict[str, list[dict]] = {}
    for wf in workflows:
        if wf["name"] in ("RunCLIProgram", "test") or not wf["actions"]:
            continue
        by_room.setdefault(wf["room"], []).append(wf)
    for b in buttons:
        cands = by_room.get(b["room"], [])
        bk = _btn_key(b["label"])
        hits = []
        for wf in cands:
            wk = _wf_key(wf["name"])
            if wk == bk or (bk == "music" and wk in ("music", "music on")) \
               or (bk == "broadcast" and wk.startswith("broadcast")) \
               or (bk == "movie" and wk.startswith("movie")) \
               or (bk == "home off" and wk == "home off") \
               or (bk == "room off" and wk == "room off"):
                hits.append(wf)
        if hits:
            b["savant_workflows"] = [f"{w['name']} [{w['service']}]" for w in hits]
            b["savant_actions"] = [a["text"] for w in hits for a in w["actions"]]


def audio_zone_rooms(wiring: dict, rooms: dict | None = None) -> dict:
    """'Output Module :: Analog Audio Out 3' -> 'Home Office' (room of the speakers it feeds)."""
    zones = {}
    rooms = rooms or {}
    for k, speakers in wiring.items():
        comp, _, outp = k.partition(" :: ")
        m = re.search(r"(\d+)\s*$", outp)
        room = rooms.get(speakers) or re.sub(r"\s*(Speakers?|Beolab ?50.*)$", "", speakers).strip()
        if m:
            zones[f"{comp}:Audio Zone {m.group(1)}"] = room
        else:
            zones[f"{comp}:{outp}"] = room
    return zones


def zones_for_actions(actions: list[str], zones: dict) -> list[str]:
    hit = []
    for a in actions:
        for key, room in zones.items():
            comp, _, logical = key.partition(":")
            if a.startswith(comp + " / " + logical + ":") and room not in hit:
                hit.append(room)
    return hit


# ------------------------------------------------------------------ main entry

def import_folder(root: str) -> tuple[dict, Findings]:
    """Read a RacePointMedia copy -> (devices.yaml-style map, Findings)."""
    files = find_files(root)
    if "lite" not in files:
        raise FileNotFoundError("LiteInterfaceConfiguration.plist not found under " + root)
    f = Findings(source_root=os.path.abspath(root))
    lighting = parse_lighting(files["lite"])
    f.system_name = lighting.get("controller_name", "")
    f.bridge_uid = lighting.get("bridge_uid", "")
    f.bridge_mac = mac_from_uid(f.bridge_uid)
    f.lutron_areas = lighting["areas"]
    f.bridge_ip, _ = parse_network_device(files.get("networkdevice", []))
    f.processor_mac = parse_controllers(files.get("controllers", []))
    ola = parse_ola(files.get("olaconfig", []))
    workflows = parse_workflows(files.get("workflows", []))
    f.workflows = workflows
    devices, wiring = parse_user_connection(files["userconn"]) if "userconn" in files else ([], {})
    rooms = parse_zone_config(files["zonecfg"]) if "zonecfg" in files else {}
    for d in devices:
        d["room"] = rooms.get(d["name"], "")
    f.devices = devices
    f.audio_zones = audio_zone_rooms(wiring, rooms)
    if "sysinfo" in files:
        try:
            f.system_name = _load_plist(files["sysinfo"]).get("RPMSystemName") or f.system_name
        except Exception:
            pass
    if "loadgroups" in files:
        f.load_levels = parse_loadgroups(files["loadgroups"])

    link_buttons_to_workflows(lighting["buttons"], workflows)

    # ---- build the device map (devices.yaml schema)
    areas: dict = {}

    def area(name: str) -> dict:
        return areas.setdefault((name or "unsorted").lower(), {"outputs": {}, "keypads": {}})

    for l in lighting["loads"]:
        zid = _href_num(l["href"])
        if zid is None:
            continue
        kind = "switch" if l["subtype"] == "RELAY" else "dimmer"
        entry = {"id": zid, "kind": kind, "href": l["href"], "savant_load_id": l["load_id"]}
        if ola.get(l["href"]):
            entry["lutron_area"] = ola[l["href"]]
        if l["name"] in f.load_levels:
            entry["level_at_export"] = f.load_levels[l["name"]]
        area(l["room"])["outputs"][l["name"]] = entry
    for s in lighting["shades"]:
        zid = _href_num(s["href"])
        if zid is None:
            continue
        area(s["room"])["outputs"][s["name"]] = {"id": zid, "kind": "shade", "href": s["href"],
                                                 "savant_load_id": s["load_id"]}
    # Buttons: Savant does not say which physical keypad each one is on, only the room.
    # One "keypad" per room, numbered by Savant's offset; the LEAP tree import regroups
    # them by real keypad once paired (hrefs match).
    for b in lighting["buttons"]:
        bid = _href_num(b["href"])
        if bid is None:
            continue
        kind, intent = classify_button(b["label"])
        kp = area(b["room"])["keypads"].setdefault(f"{b['room'].lower()} keypads",
                                                    {"id": None, "buttons": {}})
        entry = {"label": b["label"], "kind": kind, "intent": intent,
                 "href": b["href"], "led": b["led"], "savant_offset": b["offset"]}
        if b.get("savant_workflows"):
            entry["savant_workflows"] = b["savant_workflows"]
            entry["savant_actions"] = b["savant_actions"]
            z = zones_for_actions(b["savant_actions"], f.audio_zones)
            if z:
                entry["audio_zones"] = z
            if any("Spotify preset" in a for a in b["savant_actions"]):
                entry["audio_source"] = "Savant Music (Spotify preset on the media server)"
            entry["savant_captured"] = True
            entry["note"] = "linked to the Savant workflow by name (inferred); confirm live"
        kp["buttons"][bid] = entry

    f.counts = {"rooms": len(areas), "loads": len(lighting["loads"]), "shades": len(lighting["shades"]),
                "buttons": len(lighting["buttons"]), "workflows": len(workflows), "devices": len(devices)}
    if not f.processor_mac:
        f.notes.append("statusfiles/controllers/* missing: processor MAC unknown")
    if not f.bridge_ip:
        f.notes.append("lighting/shm/sdo/NetworkDevice/* missing: bridge IP unknown")

    dmap = {
        "system": "LEAP",
        "processor": None,
        "source": f"Savant configuration import ({os.path.basename(f.source_root) or root})",
        "savant": {
            "bridge_ip": f.bridge_ip, "bridge_mac": f.bridge_mac, "bridge_uid": f.bridge_uid,
            "processor_mac": f.processor_mac, "system_name": f.system_name,
        },
        "areas": areas,
    }
    return dmap, f


def findings_markdown(f: Findings) -> str:
    o = []
    o.append("## Savant configuration findings")
    o.append("")
    o.append("| Item | Value |")
    o.append("|---|---|")
    o.append(f"| Savant system | {f.system_name or 'unknown'} |")
    o.append(f"| Lighting | Lutron, driven over LEAP by Savant's LEAP Integration Bridge |")
    o.append(f"| Savant LEAP bridge | IP `{f.bridge_ip or '?'}`, MAC `{f.bridge_mac or '?'}` (hostname rpe-am335x) |")
    o.append(f"| Lutron processor MAC | `{f.processor_mac or 'unknown'}` (the host with TLS 8081 that carries this MAC) |")
    c = f.counts
    o.append(f"| Imported | {c.get('rooms', 0)} rooms, {c.get('buttons', 0)} keypad buttons, {c.get('loads', 0)} loads, {c.get('shades', 0)} shade groups |")
    o.append("")
    if f.lutron_areas:
        o.append("### Lutron areas per Savant room")
        o.append("")
        for room, hrefs in sorted(f.lutron_areas.items()):
            o.append(f"- {room}: `{'`, `'.join(hrefs)}`")
        o.append("")
    if f.audio_zones:
        o.append("### Audio zones")
        o.append("")
        o.append("| Amplifier output | Room |")
        o.append("|---|---|")
        for k, room in sorted(f.audio_zones.items()):
            o.append(f"| {k} | {room} |")
        o.append("")
    if f.devices:
        o.append("### AV and environment devices Savant controls")
        o.append("")
        o.append("| Device | Room | Address | Port | Protocol | Credentials in config |")
        o.append("|---|---|---|---|---|---|")
        for d in sorted(f.devices, key=lambda x: (x['room'], x['name'])):
            o.append(f"| {d['name']} | {d['room']} | `{d['ip']}` | {d['port']} | {d['protocol']} | {'`' + d['credentials'] + '`' if d['credentials'] else ''} |")
        o.append("")
    wfs = [w for w in f.workflows if w["actions"] and w["name"] not in ("RunCLIProgram", "test")]
    if wfs:
        o.append("### Savant workflows (what the non-lighting buttons do)")
        o.append("")
        for w in wfs:
            o.append(f"- **{w['room']} · {w['name']}** ({w['service']})")
            for a in w["actions"][:6]:
                o.append(f"  - {a['text']}")
            if len(w["actions"]) > 6:
                o.append(f"  - … {len(w['actions']) - 6} more")
        o.append("")
    if f.notes:
        o.append("Notes: " + "; ".join(f.notes))
        o.append("")
    return "\n".join(o)
