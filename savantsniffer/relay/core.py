"""Relay engine: device map + one LEAP connection + activity log + event bus.

Everything the HTTP layer needs is here, with no Flask in sight, so it can be
tested with a fake backend and reused by other front ends.

Safety model (unchanged from the rest of the project):
  * one connection to the processor, reconnected only when it drops;
  * nothing is sent that changes lights until control is switched on in the
    dashboard (persisted in relay.yaml); every command is logged with its source;
  * no configuration on the processor or the Savant host is ever touched.
"""
from __future__ import annotations

import asyncio
import collections
import datetime as dt
import json
import os
import queue
import secrets
import threading
import time
from dataclasses import dataclass, field, asdict

import yaml

from ..devicemap import DeviceMap


# ------------------------------------------------------------------ config

@dataclass
class RelayConfig:
    processor: str = ""
    certs_dir: str = "leap-certs"
    map_path: str = "devices.yaml"
    scenes_path: str = "scenes.yaml"
    log_path: str = "relay.log"
    bind: str = "0.0.0.0"
    port: int = 8765
    token: str = ""
    control_enabled: bool = False
    name: str = "lutron-relay"

    @classmethod
    def load(cls, path: str) -> "RelayConfig":
        cfg = cls()
        if os.path.exists(path):
            with open(path) as f:
                data = yaml.safe_load(f) or {}
            for k, v in data.items():
                if hasattr(cfg, k) and v is not None:
                    setattr(cfg, k, v)
        if not cfg.token:
            cfg.token = secrets.token_urlsafe(24)
        base = os.path.dirname(os.path.abspath(path))
        for attr in ("certs_dir", "map_path", "scenes_path", "log_path"):
            p = getattr(cfg, attr)
            if p and not os.path.isabs(p):
                setattr(cfg, attr, os.path.join(base, p))
        return cfg

    def save(self, path: str) -> None:
        base = os.path.dirname(os.path.abspath(path))
        data = asdict(self)
        for attr in ("certs_dir", "map_path", "scenes_path", "log_path"):
            p = data[attr]
            if p and os.path.isabs(p) and os.path.dirname(p) == base:
                data[attr] = os.path.basename(p)
        with open(path, "w") as f:
            f.write("# savantsniffer relay configuration. The token is the only secret: keep this file private.\n")
            yaml.safe_dump(data, f, sort_keys=False)


# ------------------------------------------------------------------ records

@dataclass
class LogEntry:
    ts: str
    kind: str          # event | command | system | denied | error
    text: str
    source: str = ""   # client name / ip for commands

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass
class ClientInfo:
    ip: str
    name: str = ""
    agent: str = ""
    first_seen: str = ""
    last_seen: str = ""
    requests: int = 0
    commands: int = 0

    def as_dict(self) -> dict:
        return asdict(self)


def now_iso() -> str:
    return dt.datetime.now().isoformat(timespec="milliseconds")


# ------------------------------------------------------------------ backends

class Backend:
    """What the relay needs from the processor link. Implemented by LEAPBackend
    (real) and FakeBackend (tests / demo)."""
    name = "none"

    def start(self, relay: "Relay") -> None: ...
    def stop(self) -> None: ...
    def connected(self) -> bool: return False
    def set_level(self, device_id: str, level: float, fade: float | None) -> None: raise NotImplementedError
    def press(self, button_id: str) -> None: raise NotImplementedError
    def tree(self) -> dict: return {"areas": [], "devices": [], "buttons": []}


class FakeBackend(Backend):
    """Pretends to be a processor: every SET echoes a level event, every PRESS a
    press/release pair. Used by the tests and by `lutron relay --demo`."""
    name = "demo"

    def __init__(self, tree: dict | None = None):
        self._relay: Relay | None = None
        self._tree = tree or {"areas": [], "devices": [], "buttons": []}
        self._up = False

    def start(self, relay):
        self._relay = relay; self._up = True
        relay.on_connected(self._tree)

    def stop(self):
        self._up = False

    def connected(self): return self._up

    def set_level(self, device_id, level, fade):
        self._relay.on_level(device_id, level)

    def press(self, button_id):
        self._relay.on_button(button_id, "Press")
        self._relay.on_button(button_id, "Release")

    def tree(self): return self._tree


class LEAPBackend(Backend):
    """pylutron-caseta on its own asyncio thread; reconnects when the link drops."""
    name = "LEAP"

    def __init__(self, host: str, certs_dir: str):
        self.host = host
        self.certs_dir = certs_dir
        self._relay: Relay | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._bridge = None
        self._stop = threading.Event()
        self._tree: dict = {"areas": [], "devices": [], "buttons": []}

    # -- lifecycle
    def start(self, relay):
        self._relay = relay
        self._thread = threading.Thread(target=self._run, name="leap", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._loop and self._bridge:
            try:
                asyncio.run_coroutine_threadsafe(self._bridge.close(), self._loop).result(5)
            except Exception:
                pass

    def connected(self):
        try:
            return bool(self._bridge and self._bridge.is_connected())
        except Exception:
            return False

    def tree(self): return self._tree

    # -- commands (called from Flask threads)
    def _call(self, coro, timeout=10):
        if not self._loop or not self._bridge:
            raise RuntimeError("not connected to the processor")
        return asyncio.run_coroutine_threadsafe(coro, self._loop).result(timeout)

    def set_level(self, device_id, level, fade):
        f = dt.timedelta(seconds=float(fade)) if fade else None
        self._call(self._bridge.set_value(device_id, level, f))

    def press(self, button_id):
        self._call(self._bridge.tap_button(button_id))

    # -- the thread
    def _run(self):
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._main())
        finally:
            self._loop.close()

    async def _main(self):
        from pylutron_caseta.smartbridge import Smartbridge
        key = os.path.join(self.certs_dir, "caseta.key")
        crt = os.path.join(self.certs_dir, "caseta.crt")
        ca = os.path.join(self.certs_dir, "caseta-bridge.crt")
        for p in (key, crt, ca):
            if not os.path.exists(p):
                self._relay.log("error", f"missing pairing file {p}; pair from the Mac app and copy the three files into {self.certs_dir}")
                return
        delay = 5
        while not self._stop.is_set():
            try:
                self._relay.log("system", f"connecting to {self.host}:8081 (LEAP)")
                bridge = Smartbridge.create_tls(self.host, key, crt, ca)
                await bridge.connect()
                self._bridge = bridge
                self._tree = self._build_tree(bridge)
                self._subscribe(bridge)
                self._relay.on_connected(self._tree)
                delay = 5
                while not self._stop.is_set() and bridge.is_connected():
                    await asyncio.sleep(2)
                if self._stop.is_set():
                    break
                self._relay.log("system", "connection to the processor dropped; reconnecting")
            except Exception as e:  # noqa: BLE001
                self._relay.log("error", f"LEAP: {e}; retry in {delay}s")
            self._bridge = None
            self._relay.on_disconnected()
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60)

    def _build_tree(self, bridge) -> dict:
        def area_name(aid):
            a = (bridge.areas or {}).get(str(aid)) or (bridge.areas or {}).get(aid) or {}
            return a.get("name", "") if isinstance(a, dict) else ""
        devices = [{
            "id": str(k), "name": v.get("name", ""), "type": v.get("type", ""), "model": v.get("model", ""),
            "area": area_name(v.get("area")),
            "zone": (str(v["zone"]) if v.get("zone") is not None else None),
            "level": (float(v["current_state"]) if isinstance(v.get("current_state"), (int, float)) else None),
        } for k, v in (bridge.devices or {}).items()]
        buttons = [{
            "id": str(k), "parent": str(v.get("parent_device", "")),
            "number": (int(v["button_number"]) if v.get("button_number") is not None else None),
            "name": v.get("device_name") or v.get("name") or "",
        } for k, v in (getattr(bridge, "buttons", None) or {}).items()]
        areas = [{"id": str(k), "name": v.get("name", "")} for k, v in (bridge.areas or {}).items()]
        return {"areas": areas, "devices": devices, "buttons": buttons}

    def _subscribe(self, bridge):
        relay = self._relay
        for b in self._tree["buttons"]:
            bid = b["id"]
            try:
                bridge.add_button_subscriber(bid, lambda ev, bid=bid: relay.on_button(bid, str(ev)))
            except Exception as e:  # noqa: BLE001
                relay.log("system", f"button {bid} not subscribable: {e}")
        for d in self._tree["devices"]:
            if d.get("zone") is None:
                continue
            did = d["id"]
            def cb(did=did):
                dev = bridge.devices.get(did) or {}
                lvl = dev.get("current_state")
                if lvl is not None:
                    relay.on_level(did, float(lvl))
            try:
                bridge.add_subscriber(did, cb)
            except Exception as e:  # noqa: BLE001
                relay.log("system", f"device {did} not subscribable: {e}")


# ------------------------------------------------------------------ the relay

class Relay:
    def __init__(self, cfg: RelayConfig, backend: Backend, config_path: str | None = None):
        self.cfg = cfg
        self.backend = backend
        self.config_path = config_path
        self.started = time.time()
        self.dmap = DeviceMap.load(cfg.map_path)
        self.levels: dict[str, float] = {}           # device id -> level
        self.zone_to_device: dict[str, str] = {}     # LEAP zone number -> device id
        self.device_to_zone: dict[str, str] = {}
        self.tree: dict = {"areas": [], "devices": [], "buttons": []}
        self.log_entries: collections.deque[LogEntry] = collections.deque(maxlen=1000)
        self.clients: dict[str, ClientInfo] = {}
        self.subscribers: list[queue.Queue] = []
        self.lock = threading.RLock()
        self.scenes: dict = self._load_scenes()
        self._index_map()

    # ---------------- map helpers
    def _index_map(self):
        """Name indexes: outputs by zone/id, buttons by LEAP button id."""
        self.outputs: dict[str, dict] = {}   # key "zone:<n>" or "id:<n>" -> {area, name, kind}
        self.buttons: dict[str, dict] = {}   # button id -> {area, keypad, label, kind, ...}
        for area, adata in self.dmap.areas().items():
            for oname, od in (adata.get("outputs") or {}).items():
                entry = {"area": area, "name": oname, "kind": od.get("kind", "dimmer"), "id": od.get("id"), "href": od.get("href")}
                if od.get("href", "").startswith("/zone/"):
                    self.outputs["zone:" + od["href"].rsplit("/", 1)[1]] = entry
                self.outputs["id:" + str(od.get("id"))] = entry
            for kname, kd in (adata.get("keypads") or {}).items():
                for bkey, b in (kd.get("buttons") or {}).items():
                    if not isinstance(b, dict):
                        continue
                    href = b.get("href") or ""
                    bid = href.rsplit("/", 1)[1] if href.startswith("/button/") else None
                    entry = {"area": area, "keypad": kname, "label": b.get("label", str(bkey)), "kind": b.get("kind", "output"),
                             "number": b.get("button"), "id": bid, "keypad_id": kd.get("id"),
                             "savant_actions": b.get("savant_actions") or [], "audio_zones": b.get("audio_zones") or []}
                    if bid:
                        self.buttons[bid] = entry

    def output_for_device(self, device_id: str) -> dict | None:
        z = self.device_to_zone.get(device_id)
        if z and ("zone:" + z) in self.outputs:
            return self.outputs["zone:" + z]
        return self.outputs.get("id:" + device_id)

    def device_for_output(self, phrase: str) -> tuple[str, dict]:
        """'home office office downlight' -> (device id, map entry). Raises KeyError."""
        ref = self.dmap.resolve_output(phrase)
        entry = self.outputs.get("id:" + str(ref.id)) or {"area": ref.area, "name": ref.name, "kind": ref.kind, "id": ref.id}
        href = entry.get("href") or ""
        zone = href.rsplit("/", 1)[1] if href.startswith("/zone/") else None
        dev = self.zone_to_device.get(zone) if zone else None
        if dev is None:
            # the id may already be a device id (LIP-style map) or the zone itself
            dev = self.zone_to_device.get(str(ref.id), str(ref.id))
        return dev, entry

    def button_for(self, phrase: str) -> tuple[str, dict]:
        """'home office / broadcast' or 'kitchen vol up' -> (button id, entry). Raises KeyError."""
        p = phrase.lower().replace("/", " ").split()
        text = " ".join(p)
        hits = [(bid, e) for bid, e in self.buttons.items()
                if text == f"{e['area']} {e['label']}".lower() or text == f"{e['area']} {e['keypad']} {e['label']}".lower()]
        if not hits:
            hits = [(bid, e) for bid, e in self.buttons.items() if e["label"].lower() == text]
        if not hits:
            raise KeyError(f"no button matching {phrase!r}")
        if len(hits) > 1:
            where = ", ".join(f"{e['area']}/{e['label']}" for _, e in hits)
            raise KeyError(f"ambiguous button {phrase!r}: {where}")
        return hits[0]

    # ---------------- lifecycle
    def start(self):
        self.log("system", f"relay '{self.cfg.name}' starting; map {self.cfg.map_path}; control {'ON' if self.cfg.control_enabled else 'off'}")
        self.backend.start(self)

    def stop(self):
        self.backend.stop()
        self.log("system", "relay stopped")

    # ---------------- callbacks from the backend (any thread)
    def on_connected(self, tree: dict):
        with self.lock:
            self.tree = tree
            self.zone_to_device = {d["zone"]: d["id"] for d in tree.get("devices", []) if d.get("zone")}
            self.device_to_zone = {v: k for k, v in self.zone_to_device.items()}
            for d in tree.get("devices", []):
                if d.get("level") is not None:
                    self.levels[d["id"]] = float(d["level"])
            # buttons in the map but missing from the tree, or vice versa, are only reported
            known = {b["id"] for b in tree.get("buttons", [])}
            missing = [bid for bid in self.buttons if bid not in known]
        self.log("system", f"connected to the processor ({self.backend.name}): {len(tree.get('devices', []))} devices, "
                           f"{len(tree.get('buttons', []))} buttons; {len(self.buttons) - len(missing)} map buttons matched")
        self._emit({"type": "status", "connected": True})

    def on_disconnected(self):
        self._emit({"type": "status", "connected": False})

    def on_level(self, device_id: str, level: float):
        with self.lock:
            self.levels[device_id] = float(level)
        o = self.output_for_device(device_id)
        name = f"{o['area']} / {o['name']}" if o else f"device {device_id}"
        self.log("event", f"{name} -> {level:g}%")
        self._emit({"type": "level", "device": device_id, "level": level, "output": o})

    def on_button(self, button_id: str, action: str):
        b = self.buttons.get(button_id)
        pressed = action.lower().startswith("press")
        name = f"{b['area']} / {b['label']}" if b else f"button {button_id}"
        if pressed:
            self.log("event", f"{name} pressed")
        self._emit({"type": "button", "button": button_id, "action": "press" if pressed else "release", "entry": b})

    # ---------------- commands (from the HTTP layer)
    def _guard(self, source: str, what: str):
        if not self.cfg.control_enabled:
            self.log("denied", f"{what} (control is off)", source)
            raise PermissionError("control is switched off; enable it in the dashboard first")
        if not self.backend.connected():
            self.log("denied", f"{what} (not connected)", source)
            raise ConnectionError("not connected to the processor")

    def set_output(self, phrase: str, level: float, fade: float | None, source: str) -> dict:
        level = max(0.0, min(100.0, float(level)))
        if fade is not None:
            fade = max(0.0, min(3600.0, float(fade)))
        dev, entry = self.device_for_output(phrase)
        what = f"set {entry['area']} / {entry['name']} -> {level:g}%" + (f" over {fade:g}s" if fade else "")
        self._guard(source, what)
        self.backend.set_level(dev, level, fade)
        self.log("command", what, source)
        self._emit({"type": "command", "text": what, "source": source})
        return {"device": dev, "output": entry, "level": level, "fade": fade}

    def press_button(self, phrase: str, source: str) -> dict:
        bid, entry = self.button_for(phrase)
        what = f"press {entry['area']} / {entry['label']}"
        self._guard(source, what)
        self.backend.press(bid)
        self.log("command", what, source)
        self._emit({"type": "command", "text": what, "source": source})
        return {"button": bid, "entry": entry}

    def run_scene(self, name: str, source: str) -> dict:
        scene = self.scenes.get(name)
        if scene is None:
            raise KeyError(f"no scene named {name!r}")
        self._guard(source, f"run scene {name}")
        done = []
        for step in scene.get("steps", []):
            if "set" in step:
                done.append(self.set_output(step["set"], step.get("level", 100), step.get("fade"), source + f" [scene {name}]"))
            elif "press" in step:
                done.append(self.press_button(step["press"], source + f" [scene {name}]"))
            elif "delay" in step:
                time.sleep(min(float(step["delay"]), 30000) / 1000.0)
        self.log("command", f"scene {name}: {len(done)} steps", source)
        return {"scene": name, "steps": len(done)}

    def set_control(self, enabled: bool, source: str):
        self.cfg.control_enabled = bool(enabled)
        if self.config_path:
            self.cfg.save(self.config_path)
        self.log("system", f"control switched {'ON' if enabled else 'off'}", source)
        self._emit({"type": "control", "enabled": bool(enabled)})

    # ---------------- scenes
    def _load_scenes(self) -> dict:
        if os.path.exists(self.cfg.scenes_path):
            with open(self.cfg.scenes_path) as f:
                return yaml.safe_load(f) or {}
        return {}

    def save_scene(self, name: str, steps: list[dict], source: str):
        self.scenes[name] = {"steps": steps, "updated": now_iso()}
        with open(self.cfg.scenes_path, "w") as f:
            yaml.safe_dump(self.scenes, f, sort_keys=False)
        self.log("system", f"scene saved: {name} ({len(steps)} steps)", source)

    def delete_scene(self, name: str, source: str):
        if name in self.scenes:
            del self.scenes[name]
            with open(self.cfg.scenes_path, "w") as f:
                yaml.safe_dump(self.scenes, f, sort_keys=False)
            self.log("system", f"scene deleted: {name}", source)

    # ---------------- clients, log, events
    def touch_client(self, ip: str, name: str, agent: str, command: bool = False):
        with self.lock:
            c = self.clients.get(ip)
            if c is None:
                c = ClientInfo(ip=ip, first_seen=now_iso())
                self.clients[ip] = c
            c.last_seen = now_iso(); c.requests += 1
            if name: c.name = name
            if agent: c.agent = agent[:120]
            if command: c.commands += 1

    def log(self, kind: str, text: str, source: str = ""):
        e = LogEntry(ts=now_iso(), kind=kind, text=text, source=source)
        with self.lock:
            self.log_entries.append(e)
        try:
            with open(self.cfg.log_path, "a") as f:
                f.write(f"{e.ts} {kind:8} {text}" + (f"  [{source}]" if source else "") + "\n")
        except OSError:
            pass
        if kind != "event":
            self._emit({"type": "log", "entry": e.as_dict()})

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=500)
        with self.lock:
            self.subscribers.append(q)
        return q

    def unsubscribe(self, q: queue.Queue):
        with self.lock:
            if q in self.subscribers:
                self.subscribers.remove(q)

    def _emit(self, payload: dict):
        payload = dict(payload, ts=now_iso())
        with self.lock:
            subs = list(self.subscribers)
        for q in subs:
            try:
                q.put_nowait(payload)
            except queue.Full:
                pass

    # ---------------- views
    def status(self) -> dict:
        return {
            "name": self.cfg.name, "processor": self.cfg.processor, "backend": self.backend.name,
            "connected": self.backend.connected(), "control_enabled": self.cfg.control_enabled,
            "uptime_s": int(time.time() - self.started),
            "map": {"source": self.dmap.data.get("source"), "areas": len(self.dmap.areas()),
                    "outputs": len({v["id"] for v in self.outputs.values()}), "buttons": len(self.buttons)},
            "tree": {k: len(v) for k, v in self.tree.items()},
            "clients": len(self.clients), "scenes": len(self.scenes),
        }

    def devices_view(self) -> dict:
        rooms = []
        for area, adata in sorted(self.dmap.areas().items()):
            outs = []
            for oname, od in (adata.get("outputs") or {}).items():
                href = od.get("href") or ""
                zone = href.rsplit("/", 1)[1] if href.startswith("/zone/") else str(od.get("id"))
                dev = self.zone_to_device.get(zone, zone)
                outs.append({"name": oname, "kind": od.get("kind", "dimmer"), "zone": zone, "device": dev,
                             "level": self.levels.get(dev), "phrase": f"{area} {oname}"})
            btns = []
            for kname, kd in (adata.get("keypads") or {}).items():
                for bkey, b in (kd.get("buttons") or {}).items():
                    if not isinstance(b, dict):
                        continue
                    href = b.get("href") or ""
                    btns.append({"label": b.get("label", str(bkey)), "kind": b.get("kind", "output"), "keypad": kname,
                                 "id": href.rsplit("/", 1)[1] if href.startswith("/button/") else None,
                                 "phrase": f"{area} / {b.get('label', bkey)}",
                                 "savant": b.get("savant_actions") or [], "audio_zones": b.get("audio_zones") or []})
            rooms.append({"name": area, "outputs": outs, "buttons": btns})
        return {"rooms": rooms}

    def recent_log(self, limit: int = 200, kinds: set[str] | None = None) -> list[dict]:
        with self.lock:
            items = [e.as_dict() for e in self.log_entries if not kinds or e.kind in kinds]
        return items[-limit:]

    def clients_view(self) -> list[dict]:
        with self.lock:
            return sorted((c.as_dict() for c in self.clients.values()), key=lambda c: c["last_seen"], reverse=True)


def sse_line(payload: dict) -> str:
    return "data: " + json.dumps(payload, default=str) + "\n\n"
