"""HTTP API + dashboard for the relay (Flask).

Auth: every /api call needs the token from relay.yaml, as `X-Relay-Token: <token>`
or `?token=<token>`. The dashboard asks for it once and keeps it in the browser.

Endpoints (all JSON):
  GET  /api/status                      connection, control switch, counts
  GET  /api/devices                     rooms -> loads (with live levels) and keypad buttons
  GET  /api/log?limit=200&kinds=command,event
  GET  /api/clients                     who has been talking to the relay
  GET  /api/scenes                      saved scenes
  PUT  /api/scenes/<name>  {steps:[{set,level,fade}|{press}|{delay}]}
  DELETE /api/scenes/<name>
  POST /api/set     {output:"kitchen island", level:20, fade:2}
  POST /api/press   {button:"home office / broadcast"}
  POST /api/scene/<name>/run
  POST /api/control {enabled:true|false}
  GET  /api/events                      server-sent events: level, button, command, log, status
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from flask import Flask, Response, abort, jsonify, request, send_from_directory, stream_with_context

from .core import FakeBackend, LEAPBackend, Relay, RelayConfig, sse_line

HERE = os.path.dirname(os.path.abspath(__file__))


def create_app(relay: Relay) -> Flask:
    app = Flask(__name__, static_folder=None)

    def source() -> str:
        name = request.headers.get("X-Client-Name", "").strip()
        ip = request.remote_addr or "?"
        return f"{name} @ {ip}" if name else ip

    @app.before_request
    def auth():
        if not request.path.startswith("/api/"):
            return None
        tok = request.headers.get("X-Relay-Token") or request.args.get("token") or ""
        if tok != relay.cfg.token:
            abort(401, description="missing or wrong X-Relay-Token")
        relay.touch_client(request.remote_addr or "?", request.headers.get("X-Client-Name", ""),
                           request.headers.get("User-Agent", ""),
                           command=(request.method == "POST" and request.path.startswith(("/api/set", "/api/press", "/api/scene/"))))
        return None

    @app.errorhandler(401)
    def _401(e): return jsonify(error=str(e.description)), 401

    @app.errorhandler(404)
    def _404(e): return jsonify(error="not found"), 404

    # ---- pages
    @app.get("/")
    def index():
        return send_from_directory(HERE, "dashboard.html")

    # ---- read
    @app.get("/api/status")
    def status(): return jsonify(relay.status())

    @app.get("/api/devices")
    def devices(): return jsonify(relay.devices_view())

    @app.get("/api/log")
    def log():
        limit = min(int(request.args.get("limit", 200)), 1000)
        kinds = request.args.get("kinds")
        return jsonify(relay.recent_log(limit, set(kinds.split(",")) if kinds else None))

    @app.get("/api/clients")
    def clients(): return jsonify(relay.clients_view())

    @app.get("/api/scenes")
    def scenes(): return jsonify(relay.scenes)

    @app.get("/api/tree")
    def tree(): return jsonify(relay.tree)

    # ---- write
    def body() -> dict:
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            abort(400, description="JSON body expected")
        return data

    def run(fn):
        try:
            return jsonify(ok=True, result=fn())
        except PermissionError as e:
            return jsonify(ok=False, error=str(e)), 403
        except ConnectionError as e:
            return jsonify(ok=False, error=str(e)), 503
        except KeyError as e:
            return jsonify(ok=False, error=str(e).strip("'\"")), 404
        except (TypeError, ValueError) as e:
            return jsonify(ok=False, error=str(e)), 400
        except Exception as e:  # noqa: BLE001
            relay.log("error", f"{fn.__name__ if hasattr(fn, '__name__') else 'command'}: {e}", source())
            return jsonify(ok=False, error=str(e)), 500

    @app.post("/api/set")
    def api_set():
        d = body()
        return run(lambda: relay.set_output(str(d.get("output", "")), float(d.get("level", 0)),
                                            (float(d["fade"]) if d.get("fade") not in (None, "") else None), source()))

    @app.post("/api/press")
    def api_press():
        d = body()
        return run(lambda: relay.press_button(str(d.get("button", "")), source()))

    @app.post("/api/scene/<name>/run")
    def api_scene_run(name):
        return run(lambda: relay.run_scene(name, source()))

    @app.put("/api/scenes/<name>")
    def api_scene_put(name):
        d = body()
        steps = d.get("steps")
        if not isinstance(steps, list) or not steps:
            abort(400, description="steps must be a non-empty list")
        relay.save_scene(name, steps, source())
        return jsonify(ok=True)

    @app.delete("/api/scenes/<name>")
    def api_scene_delete(name):
        relay.delete_scene(name, source())
        return jsonify(ok=True)

    @app.post("/api/control")
    def api_control():
        d = body()
        relay.set_control(bool(d.get("enabled")), source())
        return jsonify(ok=True, control_enabled=relay.cfg.control_enabled)

    # ---- events
    @app.get("/api/events")
    def events():
        q = relay.subscribe()

        @stream_with_context
        def gen():
            try:
                yield sse_line({"type": "hello", "status": relay.status()})
                while True:
                    try:
                        item = q.get(timeout=15)
                        yield sse_line(item)
                    except Exception:
                        yield ": keepalive\n\n"
            finally:
                relay.unsubscribe(q)
        return Response(gen(), mimetype="text/event-stream",
                        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    return app


def build_relay(config_path: str, demo: bool = False) -> Relay:
    cfg = RelayConfig.load(config_path)
    if not os.path.exists(config_path):
        cfg.save(config_path)
    if demo:
        backend = FakeBackend(_demo_tree(cfg))
    else:
        if not cfg.processor:
            raise SystemExit(f"processor is not set in {config_path}; add  processor: 192.168.1.201")
        backend = LEAPBackend(cfg.processor, cfg.certs_dir)
    return Relay(cfg, backend, config_path)


def _demo_tree(cfg: RelayConfig) -> dict:
    """A tree that matches the map so the demo answers by name."""
    from ..devicemap import DeviceMap
    dmap = DeviceMap.load(cfg.map_path)
    devices, buttons = [], []
    for area, adata in dmap.areas().items():
        for oname, od in (adata.get("outputs") or {}).items():
            z = str(od.get("id"))
            devices.append({"id": "d" + z, "name": oname, "type": "Dimmed" if od.get("kind") == "dimmer" else "Switched",
                            "area": area, "zone": z, "level": 0.0})
        for kname, kd in (adata.get("keypads") or {}).items():
            for bkey, b in (kd.get("buttons") or {}).items():
                href = (b.get("href") if isinstance(b, dict) else "") or ""
                if href.startswith("/button/"):
                    buttons.append({"id": href.rsplit("/", 1)[1], "parent": "k" + area, "number": None, "name": kname})
    return {"areas": [{"id": a, "name": a} for a in dmap.areas()], "devices": devices, "buttons": buttons}


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="lutron relay", description="Run the relay service.")
    p.add_argument("--config", default="relay.yaml", help="configuration file (created on first run)")
    p.add_argument("--demo", action="store_true", help="no processor: fake backend that echoes commands (for trying the dashboard)")
    p.add_argument("--port", type=int, help="override the port in the config")
    p.add_argument("--bind", help="override the bind address in the config")
    a = p.parse_args(argv)
    relay = build_relay(a.config, demo=a.demo)
    if a.port: relay.cfg.port = a.port
    if a.bind: relay.cfg.bind = a.bind
    app = create_app(relay)
    relay.start()
    print(f"relay '{relay.cfg.name}' on http://{relay.cfg.bind}:{relay.cfg.port}  (token in {a.config})")
    print(f"control is {'ON' if relay.cfg.control_enabled else 'OFF (observe only; switch it on in the dashboard)'}")
    try:
        app.run(host=relay.cfg.bind, port=relay.cfg.port, threaded=True, use_reloader=False)
    finally:
        relay.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
