"""Local web UI for discovery, monitoring, labelling, and (gated) control.

Runs on 127.0.0.1 only. Start with:  python -m savantsniffer.webapp
Then open http://127.0.0.1:8765

Live-labelling workflow (the key feature):
  * Start the monitor. Walk the house pressing keypad buttons / dimming loads.
  * Each ~DEVICE / ~OUTPUT event streams into the browser in real time.
  * Click an event, type the room + function name, Save -> it's written into
    devices.yaml with the right integration id / button number.

Observe-first: control actions require an explicit confirm checkbox per request.
"""
from __future__ import annotations
import datetime as _dt
import json
import queue
import threading
from collections import deque

from flask import Flask, Response, jsonify, render_template, request

from . import osdetect, discovery, portcheck
from .devicemap import DeviceMap
from .controller import Controller, NotArmed
from .macros import MacroRecorder

app = Flask(__name__)


class MonitorManager:
    """Owns the single LIP session and fans events out to browser listeners."""
    def __init__(self):
        self.thread: threading.Thread | None = None
        self.stop_flag = threading.Event()
        self.events: deque = deque(maxlen=500)
        self.listeners: list[queue.Queue] = []
        self.lock = threading.Lock()
        self.status = "stopped"
        self.system = None
        self.logpath = None
        self.recorder = MacroRecorder()
        self.client = None   # live LIPClient while monitoring (reused for control)

    def running(self) -> bool:
        return self.thread is not None and self.thread.is_alive()

    def start(self, host, port, user, pw):
        if self.running():
            return False, "already running"
        self.stop_flag.clear()
        self.logpath = f"logs/monitor-{_dt.datetime.now():%Y%m%d-%H%M%S}.log"
        self.thread = threading.Thread(
            target=self._run, args=(host, port, user, pw), daemon=True)
        self.thread.start()
        return True, self.logpath

    def stop(self):
        self.stop_flag.set()

    def _emit(self, obj: dict):
        self.events.append(obj)
        with self.lock:
            dead = []
            for q in self.listeners:
                try:
                    q.put_nowait(obj)
                except queue.Full:
                    dead.append(q)
            for q in dead:
                self.listeners.remove(q)

    def _run(self, host, port, user, pw):
        from .lip import LIPClient
        self.status = "connecting"
        try:
            with LIPClient(host, port=int(port), username=user, password=pw) as c, \
                 open(self.logpath, "a", buffering=1) as f:
                self.client = c
                self.system = c.system
                self.status = "monitoring"
                c.enable_monitoring()
                self._emit({"kind": "STATUS", "raw": f"connected: {c.system} {c.prompt}",
                            "ts": _dt.datetime.now().isoformat()})
                f.write(f"# monitor start {_dt.datetime.now().isoformat()} {c.system}\n")
                for ev in c.read_events(stop=self.stop_flag.is_set):
                    if ev.kind in ("DEVICE", "OUTPUT"):
                        self.recorder.feed(ev.raw)
                        obj = {"kind": ev.kind, "raw": ev.raw,
                               "ts": ev.ts.isoformat(timespec="milliseconds"),
                               "capturing": self.recorder.active is not None}
                        obj.update(_parse_ids(ev.raw))
                        self._emit(obj)
                        f.write(ev.format() + "\n")
        except Exception as e:
            self._emit({"kind": "ERROR", "raw": str(e), "ts": _dt.datetime.now().isoformat()})
        finally:
            self.client = None
            self.status = "stopped"
            self._emit({"kind": "STATUS", "raw": "session closed",
                        "ts": _dt.datetime.now().isoformat()})

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=200)
        with self.lock:
            self.listeners.append(q)
        return q


def _parse_ids(raw: str) -> dict:
    """Pull integration id / button / level out of a ~DEVICE or ~OUTPUT line."""
    parts = raw.split(",")
    out: dict = {}
    if raw.startswith("~DEVICE") and len(parts) >= 4:
        out = {"id": parts[1], "component": parts[2], "action": parts[3].strip()}
    elif raw.startswith("~OUTPUT") and len(parts) >= 4:
        out = {"id": parts[1], "action": parts[2], "level": parts[3].strip()}
    return out


mgr = MonitorManager()


def _env():
    import os
    try:
        from dotenv import dotenv_values
        v = dict(dotenv_values(".env"))
    except Exception:
        v = {}
    for k, val in os.environ.items():
        v.setdefault(k, val)
    return v


@app.route("/")
def index():
    info = osdetect.detect()
    return render_template("index.html",
                           osinfo=info.pretty,
                           tools=info.tools,
                           scanner=osdetect.preferred_scanner(info) or "none",
                           env=_env())


@app.route("/api/scan-command")
def scan_command():
    subnet = request.args.get("subnet") or None
    plan = discovery.build_scan_command(subnet=subnet)
    return jsonify({"command": plan.shown, "tool": plan.tool,
                    "subnet": plan.subnet, "note": plan.note})


@app.route("/api/scan", methods=["POST"])
def scan():
    # Requires explicit confirm=true from the UI (user saw the command first).
    body = request.get_json(force=True)
    if not body.get("confirm"):
        return jsonify({"error": "not confirmed"}), 400
    plan = discovery.build_scan_command(subnet=body.get("subnet") or None)
    try:
        # No terminal here for sudo to prompt on, so run unprivileged.
        hosts, raw = discovery.run_scan(plan, sudo=False)
    except FileNotFoundError:
        return jsonify({"error": f"{plan.tool} not installed"}), 500
    buckets = discovery.classify_hosts(hosts)
    note = ""
    if plan.needs_sudo:
        note = (f"Ran without root. For MAC/vendor data run in Terminal: {plan.shown}"
                " — or use `sudo lutron discover`.")
    return jsonify({"buckets": {k: [vars(h) for h in v] for k, v in buckets.items()},
                    "command": plan.shown, "note": note})


@app.route("/api/portcheck")
def api_portcheck():
    host = request.args.get("host", "")
    if not host:
        return jsonify({"error": "host required"}), 400
    rep = portcheck.probe(host)
    label, why = rep.likely_system()
    return jsonify({"host": host,
                    "results": [vars(r) for r in rep.results],
                    "system": label, "why": why})


@app.route("/api/monitor/start", methods=["POST"])
def monitor_start():
    env = _env()
    body = request.get_json(force=True) or {}
    host = body.get("host") or env.get("LUTRON_HOST")
    if not host:
        return jsonify({"error": "no host"}), 400
    ok, info = mgr.start(host,
                         env.get("LUTRON_LIP_PORT", 23),
                         env.get("LUTRON_LIP_USER", "lutron"),
                         env.get("LUTRON_LIP_PASSWORD", "integration"))
    return jsonify({"ok": ok, "info": info, "status": mgr.status})


@app.route("/api/monitor/stop", methods=["POST"])
def monitor_stop():
    mgr.stop()
    return jsonify({"ok": True})


@app.route("/api/monitor/stream")
def monitor_stream():
    q = mgr.subscribe()

    def gen():
        # replay recent
        for ev in list(mgr.events):
            yield f"data: {json.dumps(ev)}\n\n"
        while True:
            try:
                ev = q.get(timeout=15)
                yield f"data: {json.dumps(ev)}\n\n"
            except queue.Empty:
                yield ": keepalive\n\n"
    return Response(gen(), mimetype="text/event-stream")


@app.route("/api/map", methods=["GET"])
def get_map():
    dmap = DeviceMap.load()
    return jsonify(dmap.data)


@app.route("/api/map/label", methods=["POST"])
def label():
    """Add a labelled device/output from a monitored event into devices.yaml."""
    body = request.get_json(force=True)
    dmap = DeviceMap.load()
    kind = body.get("kind")
    area = (body.get("area") or "unsorted").strip().lower()
    name = (body.get("name") or "").strip()
    dev_id = int(body.get("id"))
    if not name:
        return jsonify({"error": "name required"}), 400
    if kind == "OUTPUT":
        dmap.add_output(area, name, dev_id, body.get("kindtype", "dimmer"))
    elif kind == "DEVICE":
        button = int(body.get("component") or body.get("button") or 0)
        dmap.add_keypad_button(area, name, dev_id, button, body.get("label", ""))
    else:
        return jsonify({"error": "unknown kind"}), 400
    if body.get("processor"):
        dmap.data["processor"] = body["processor"]
    if body.get("system"):
        dmap.data["system"] = body["system"]
    dmap.save()
    return jsonify({"ok": True, "map": dmap.data})


@app.route("/api/macro/begin", methods=["POST"])
def macro_begin():
    """Arm macro capture right before you press the physical button."""
    if not mgr.running():
        return jsonify({"error": "monitor not running"}), 400
    mgr.recorder.begin()
    return jsonify({"ok": True, "capturing": True})


@app.route("/api/macro/status")
def macro_status():
    r = mgr.recorder
    if r.active is None:
        return jsonify({"capturing": False})
    cap = r.active
    return jsonify({"capturing": True, "settled": r.settled(),
                    "trigger_device": cap.trigger_device,
                    "trigger_button": cap.trigger_button,
                    "kind_guess": cap.classify(),
                    "steps": [vars(s) for s in cap.steps],
                    "effect": cap.effect_set()})


@app.route("/api/macro/save", methods=["POST"])
def macro_save():
    """Finish capture and store the button (output/macro/integration) into the map."""
    body = request.get_json(force=True)
    cap = mgr.recorder.finish()
    if cap is None:
        return jsonify({"error": "nothing captured"}), 400
    area = (body.get("area") or "unsorted").strip().lower()
    keypad = (body.get("keypad") or "keypad").strip()
    kp_id = int(body.get("device") or cap.trigger_device or 0)
    button = int(body.get("button") or cap.trigger_button or 0)
    label = body.get("label", "")
    kind = body.get("kind") or cap.classify()
    dmap = DeviceMap.load()
    dmap.add_button(area, keypad, kp_id, button, label=label, kind=kind,
                    effect=cap.effect_set() if kind == "macro" else None)
    dmap.save()
    return jsonify({"ok": True, "kind": kind, "effect": cap.effect_set(), "map": dmap.data})


@app.route("/api/seed", methods=["POST"])
def api_seed():
    import os, yaml
    path = "layout.seed.yaml"
    if not os.path.exists(path):
        return jsonify({"error": "layout.seed.yaml not found"}), 404
    with open(path) as f:
        seed = yaml.safe_load(f)
    dmap = DeviceMap.load()
    added = dmap.merge_seed(seed)
    dmap.save()
    return jsonify({"ok": True, "added": added, "map": dmap.data})


@app.route("/api/control", methods=["POST"])
def control():
    """Gated control. Requires confirm=true in the body every call (observe-first)."""
    body = request.get_json(force=True)
    if not body.get("confirm"):
        return jsonify({"error": "confirm required (observe-first)"}), 400
    # Reuse the monitor's live session so we never hold two integration sessions.
    ctl = Controller(DeviceMap.load(), client=mgr.client if mgr.running() else None)
    try:
        if body["action"] == "set":
            sent = ctl.set_level(body["name"], float(body["level"]), confirm=True)
        elif body["action"] == "press":
            sent = ctl.press(body["name"], int(body["button"]), confirm=True)
        else:
            return jsonify({"error": "unknown action"}), 400
    except (KeyError, NotArmed, RuntimeError) as e:
        return jsonify({"error": str(e)}), 400
    return jsonify({"ok": True, "sent": sent})


def main():
    print("savantsniffer web UI -> http://127.0.0.1:8765  (Ctrl-C to stop)")
    app.run(host="127.0.0.1", port=8765, threaded=True, debug=False)


if __name__ == "__main__":
    main()
