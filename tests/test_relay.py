"""Relay service: name resolution, the control gate, logging, clients, SSE, scenes.
Runs against the fake backend; no network, no hardware."""
import json
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from savantsniffer.relay.core import FakeBackend, Relay, RelayConfig
from savantsniffer.relay.server import create_app, _demo_tree


MAP = {
    "system": "LEAP", "processor": "192.168.1.201", "areas": {
        "home office": {
            "outputs": {"Office Downlight": {"id": 1095, "kind": "dimmer", "href": "/zone/1095"}},
            "keypads": {"home office keypads": {"id": None, "buttons": {
                2639: {"label": "Broadcast", "kind": "integration", "href": "/button/2639", "audio_zones": ["Home Office"]},
                2622: {"label": "Room Off", "kind": "macro", "href": "/button/2622"},
            }}},
        },
        "kitchen": {
            "outputs": {"Hob": {"id": 1446, "kind": "switch", "href": "/zone/1446"}},
            "keypads": {"kitchen keypads": {"id": None, "buttons": {2900: {"label": "Room Off", "kind": "macro", "href": "/button/2900"}}}},
        },
    },
}


def make(tmp_path, control=False):
    mp = tmp_path / "devices.yaml"
    mp.write_text(yaml.safe_dump(MAP))
    cfg_path = tmp_path / "relay.yaml"
    cfg = RelayConfig.load(str(cfg_path))
    cfg.map_path = str(mp); cfg.scenes_path = str(tmp_path / "scenes.yaml"); cfg.log_path = str(tmp_path / "relay.log")
    cfg.control_enabled = control; cfg.token = "t0k"
    cfg.save(str(cfg_path))
    # a tree whose device ids differ from the zone numbers, like a real processor
    tree = {"areas": [], "devices": [
        {"id": "501", "name": "Office Downlight", "type": "Dimmed", "area": "Home Office", "zone": "1095", "level": 40.0},
        {"id": "502", "name": "Hob", "type": "Switched", "area": "Kitchen", "zone": "1446", "level": 0.0},
    ], "buttons": [{"id": "2639", "parent": "k1", "number": 1, "name": "Office keypad"},
                   {"id": "2622", "parent": "k1", "number": 2, "name": "Office keypad"},
                   {"id": "2900", "parent": "k2", "number": 1, "name": "Kitchen keypad"}]}
    relay = Relay(cfg, FakeBackend(tree), str(cfg_path))
    relay.start()
    app = create_app(relay)
    app.config["TESTING"] = True
    return relay, app.test_client(), cfg_path


H = {"X-Relay-Token": "t0k", "X-Client-Name": "pytest"}


def test_auth_required(tmp_path):
    _, c, _ = make(tmp_path)
    assert c.get("/api/status").status_code == 401
    assert c.get("/api/status", headers=H).status_code == 200
    assert c.get("/api/status?token=t0k").status_code == 200
    assert c.get("/").status_code == 200 and b"Lutron Relay" in c.get("/").data


def test_status_and_devices(tmp_path):
    relay, c, _ = make(tmp_path)
    s = c.get("/api/status", headers=H).get_json()
    assert s["connected"] is True and s["control_enabled"] is False and s["backend"] == "demo"
    assert s["map"]["outputs"] == 2 and s["map"]["buttons"] == 3
    d = c.get("/api/devices", headers=H).get_json()
    office = next(r for r in d["rooms"] if r["name"] == "home office")
    out = office["outputs"][0]
    assert out["device"] == "501" and out["level"] == 40.0 and out["phrase"] == "home office Office Downlight"
    assert office["buttons"][0]["id"] in ("2639", "2622")
    assert relay.zone_to_device == {"1095": "501", "1446": "502"}


def test_control_gate_and_log(tmp_path):
    relay, c, cfg_path = make(tmp_path)
    r = c.post("/api/set", headers=H, json={"output": "home office office downlight", "level": 20, "fade": 2})
    assert r.status_code == 403 and "switched off" in r.get_json()["error"]
    denied = [e for e in relay.recent_log() if e["kind"] == "denied"]
    assert denied and "pytest" in denied[-1]["source"]
    # switch control on through the API; it persists
    assert c.post("/api/control", headers=H, json={"enabled": True}).get_json()["control_enabled"] is True
    assert yaml.safe_load(open(cfg_path))["control_enabled"] is True
    r = c.post("/api/set", headers=H, json={"output": "home office office downlight", "level": 20, "fade": 2})
    assert r.status_code == 200 and r.get_json()["result"]["device"] == "501"
    assert relay.levels["501"] == 20.0                           # the fake echoed the level event
    cmd = [e for e in relay.recent_log() if e["kind"] == "command"][-1]
    assert "Office Downlight -> 20% over 2s" in cmd["text"] and cmd["source"].startswith("pytest @")
    # clamping
    r = c.post("/api/set", headers=H, json={"output": "kitchen hob", "level": 250})
    assert r.get_json()["result"]["level"] == 100.0


def test_press_and_ambiguity(tmp_path):
    relay, c, _ = make(tmp_path, control=True)
    r = c.post("/api/press", headers=H, json={"button": "home office / broadcast"})
    assert r.status_code == 200 and r.get_json()["result"]["button"] == "2639"
    assert any("Broadcast pressed" in e["text"] for e in relay.recent_log(kinds={"event"}))
    r = c.post("/api/press", headers=H, json={"button": "room off"})
    assert r.status_code == 404 and "ambiguous" in r.get_json()["error"]
    r = c.post("/api/press", headers=H, json={"button": "kitchen room off"})
    assert r.status_code == 200
    r = c.post("/api/press", headers=H, json={"button": "garage door"})
    assert r.status_code == 404


def test_clients_and_scenes(tmp_path):
    relay, c, _ = make(tmp_path, control=True)
    c.get("/api/status", headers=H)
    clients = c.get("/api/clients", headers=H).get_json()
    assert clients[0]["name"] == "pytest" and clients[0]["requests"] >= 1
    steps = [{"set": "home office office downlight", "level": 30}, {"press": "home office / broadcast"}, {"delay": 1}]
    assert c.put("/api/scenes/evening", headers=H, json={"steps": steps}).status_code == 200
    assert "evening" in c.get("/api/scenes", headers=H).get_json()
    r = c.post("/api/scene/evening/run", headers=H, json={})
    assert r.status_code == 200 and r.get_json()["result"]["steps"] == 2
    assert relay.levels["501"] == 30.0
    assert c.delete("/api/scenes/evening", headers=H).status_code == 200
    assert c.get("/api/scenes", headers=H).get_json() == {}
    assert c.put("/api/scenes/bad", headers=H, json={"steps": []}).status_code == 400


def test_events_stream(tmp_path):
    relay, c, _ = make(tmp_path, control=True)
    q = relay.subscribe()
    relay.on_level("502", 100.0)
    relay.on_button("2900", "Press")
    kinds = [q.get_nowait()["type"] for _ in range(2)]
    assert kinds == ["level", "button"]
    relay.unsubscribe(q)
    # the HTTP stream starts with a hello frame
    r = c.get("/api/events", headers=H)
    first = next(r.response)
    assert first.startswith(b"data: ") and json.loads(first[6:].strip())["type"] == "hello"
    r.close()


def test_demo_tree_matches_map(tmp_path):
    mp = tmp_path / "devices.yaml"; mp.write_text(yaml.safe_dump(MAP))
    cfg = RelayConfig(map_path=str(mp))
    t = _demo_tree(cfg)
    assert {d["zone"] for d in t["devices"]} == {"1095", "1446"}
    assert {b["id"] for b in t["buttons"]} == {"2639", "2622", "2900"}
