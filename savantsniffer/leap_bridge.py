#!/usr/bin/env python3
"""LEAP bridge: talks to a LEAP-generation Lutron processor (HomeWorks QSX,
RadioRA 3, RA2 Select, Caseta) via pylutron-caseta and speaks a tiny line
protocol so the Mac app (or anything else) can treat it like the telnet feed.

Standalone on purpose: it imports only pylutron_caseta, so the app can bundle
this one file and run it from a private virtualenv.

  leap_bridge.py pair  <host> --dir DIR      pair (press the processor's button), write certs to DIR
  leap_bridge.py tree  <host> --dir DIR      print the area/device/button tree as JSON
  leap_bridge.py serve <host> --dir DIR      stream events on stdout, take commands on stdin

serve output lines (identical shapes to the telnet feed):
  READY <bridge type>
  ~DEVICE,<keypad device id>,<button number>,3      press   (4 = release)
  ~OUTPUT,<device id>,1,<level>                     level change
  LOG <text> / ERR <text>
serve input lines:
  SET <device id> <level> [fade seconds]
  PRESS <device id> <button number>
  QUIT
"""
from __future__ import annotations
import argparse
import asyncio
import datetime as dt
import json
import os
import sys
import threading


def _out(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _paths(d: str) -> tuple[str, str, str]:
    os.makedirs(d, exist_ok=True)
    return (os.path.join(d, "caseta.key"), os.path.join(d, "caseta.crt"), os.path.join(d, "caseta-bridge.crt"))


# ---------------------------------------------------------------- pair
async def do_pair(host: str, d: str) -> int:
    from pylutron_caseta.pairing import async_pair
    key, cert, ca = _paths(d)
    _out("LOG Connecting to %s for pairing." % host)
    _out("LOG >>> Press the pairing button on the processor NOW (you have about 30 seconds).")
    try:
        data = await async_pair(host)
    except Exception as e:  # noqa: BLE001
        _out("ERR pairing failed: %s" % e)
        return 2
    with open(cert, "w") as f:
        f.write(data["cert"])
    with open(key, "w") as f:
        f.write(data["key"])
    with open(ca, "w") as f:
        f.write(data["ca"])
    _out("LOG Paired. Certificates written to %s" % d)
    _out("READY %s" % data.get("version", "LEAP"))
    return 0


# ---------------------------------------------------------------- connect
async def _connect(host: str, d: str):
    from pylutron_caseta.smartbridge import Smartbridge
    key, cert, ca = _paths(d)
    for p in (key, cert, ca):
        if not os.path.exists(p):
            raise FileNotFoundError("missing %s — pair first" % p)
    bridge = Smartbridge.create_tls(host, key, cert, ca)
    await bridge.connect()
    return bridge


def _area_name(bridge, area_id) -> str:
    a = (bridge.areas or {}).get(str(area_id)) or (bridge.areas or {}).get(area_id) or {}
    return a.get("name", "") if isinstance(a, dict) else ""


def _tree(bridge) -> dict:
    areas = [{"id": str(k), "name": v.get("name", "")} for k, v in (bridge.areas or {}).items()]
    devices = []
    for k, v in (bridge.devices or {}).items():
        devices.append({
            "id": str(k),
            "name": v.get("name", ""),
            "type": v.get("type", ""),
            "model": v.get("model", ""),
            "area": _area_name(bridge, v.get("area")),
            "zone": (str(v["zone"]) if v.get("zone") is not None else None),
            "level": (float(v["current_state"]) if isinstance(v.get("current_state"), (int, float)) else None),
        })
    buttons = []
    for k, v in (getattr(bridge, "buttons", None) or {}).items():
        buttons.append({
            "id": str(k),
            "parent": str(v.get("parent_device", "")),
            "number": (int(v["button_number"]) if v.get("button_number") is not None else None),
            "name": v.get("name", ""),
        })
    return {"areas": areas, "devices": devices, "buttons": buttons}


async def do_tree(host: str, d: str) -> int:
    bridge = await _connect(host, d)
    try:
        _out(json.dumps(_tree(bridge)))
    finally:
        await bridge.close()
    return 0


# ---------------------------------------------------------------- serve
async def do_serve(host: str, d: str) -> int:
    bridge = await _connect(host, d)
    loop = asyncio.get_running_loop()
    tree = _tree(bridge)
    _out("LOG connected: %d devices, %d buttons" % (len(tree["devices"]), len(tree["buttons"])))

    # (parent device id, button number) -> button id, for PRESS
    by_pos: dict[tuple[str, int], str] = {}
    for b in tree["buttons"]:
        if b["parent"] and b["number"] is not None:
            by_pos[(b["parent"], int(b["number"]))] = b["id"]

    def make_button_cb(parent: str, number):
        def cb(event_type):
            action = 3 if str(event_type).lower().startswith("press") else 4
            _out("~DEVICE,%s,%s,%d" % (parent, number, action))
        return cb

    def make_device_cb(dev_id: str):
        def cb():
            dev = bridge.devices.get(dev_id) or {}
            lvl = dev.get("current_state")
            if lvl is not None:
                _out("~OUTPUT,%s,1,%s" % (dev_id, lvl))
        return cb

    for b in tree["buttons"]:
        if b["parent"] and b["number"] is not None:
            try:
                bridge.add_button_subscriber(b["id"], make_button_cb(b["parent"], b["number"]))
            except Exception as e:  # noqa: BLE001
                _out("LOG button %s not subscribable: %s" % (b["id"], e))
    for dv in tree["devices"]:
        if dv.get("zone") is not None:
            try:
                bridge.add_subscriber(dv["id"], make_device_cb(dv["id"]))
            except Exception as e:  # noqa: BLE001
                _out("LOG device %s not subscribable: %s" % (dv["id"], e))

    _out("READY LEAP")
    queue: asyncio.Queue = asyncio.Queue()

    def reader():
        for line in sys.stdin:
            loop.call_soon_threadsafe(queue.put_nowait, line.strip())
        loop.call_soon_threadsafe(queue.put_nowait, "QUIT")
    threading.Thread(target=reader, daemon=True).start()

    try:
        while True:
            cmd = await queue.get()
            parts = cmd.split()
            if not parts:
                continue
            op = parts[0].upper()
            try:
                if op == "QUIT":
                    break
                elif op == "SET" and len(parts) >= 3:
                    dev, level = parts[1], float(parts[2])
                    fade = dt.timedelta(seconds=float(parts[3])) if len(parts) >= 4 else None
                    await bridge.set_value(dev, level, fade)
                    _out("LOG set %s -> %g%s" % (dev, level, (" over %ss" % parts[3]) if fade else ""))
                elif op == "PRESS" and len(parts) >= 3:
                    bid = by_pos.get((parts[1], int(parts[2])))
                    if not bid:
                        _out("ERR no button %s on device %s" % (parts[2], parts[1]))
                    else:
                        await bridge.tap_button(bid)
                        _out("LOG pressed %s/%s" % (parts[1], parts[2]))
                else:
                    _out("ERR unknown command: %s" % cmd)
            except Exception as e:  # noqa: BLE001
                _out("ERR %s" % e)
    finally:
        await bridge.close()
        _out("LOG closed")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="leap_bridge")
    p.add_argument("action", choices=["pair", "tree", "serve"])
    p.add_argument("host")
    p.add_argument("--dir", default=os.path.expanduser("~/Library/Application Support/SavantSniffer/leap"))
    a = p.parse_args(argv)
    try:
        import pylutron_caseta  # noqa: F401
    except ImportError:
        _out("ERR pylutron-caseta is not installed (pip install pylutron-caseta)")
        return 3
    fn = {"pair": do_pair, "tree": do_tree, "serve": do_serve}[a.action]
    try:
        return asyncio.run(fn(a.host, a.dir))
    except KeyboardInterrupt:
        return 0
    except Exception as e:  # noqa: BLE001
        _out("ERR %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
