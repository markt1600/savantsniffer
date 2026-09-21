"""LEAP support for HomeWorks QSX / RadioRA 3 / Caseta via pylutron-caseta.

Two steps:
  1. pair() — one-time. You press the physical pairing button on the bridge/processor
     when prompted; this writes caseta.key / caseta.crt / caseta-bridge.crt locally.
  2. dump_tree() — connect with those certs and print the full area/device/button/zone
     tree so you can fill devices.yaml.

pylutron-caseta is async. These are thin sync wrappers.
"""
from __future__ import annotations
import asyncio
import json
import os

KEYFILE = os.environ.get("LUTRON_LEAP_KEYFILE", "caseta.key")
CERTFILE = os.environ.get("LUTRON_LEAP_CERTFILE", "caseta.crt")
CAFILE = os.environ.get("LUTRON_LEAP_CA", "caseta-bridge.crt")


def _require_lib():
    try:
        import pylutron_caseta  # noqa: F401
    except ImportError as e:
        raise RuntimeError(
            "pylutron-caseta not installed. Install with: pip install pylutron-caseta"
        ) from e


async def _pair(host: str):
    from pylutron_caseta.pairing import async_pair
    print(f"Pairing with {host}.")
    print(">>> Press the small black button on the bridge / the pairing button on the "
          "QSX processor NOW (you have ~30s).")
    data = await async_pair(host)
    with open(CERTFILE, "w") as f:
        f.write(data["cert"])
    with open(KEYFILE, "w") as f:
        f.write(data["key"])
    with open(CAFILE, "w") as f:
        f.write(data["ca"])
    print(f"Paired. Wrote {CERTFILE}, {KEYFILE}, {CAFILE}.")
    print(f"Bridge type: {data.get('version', 'unknown')}")


def pair(host: str) -> None:
    _require_lib()
    asyncio.run(_pair(host))


async def _connect(host: str):
    from pylutron_caseta.smartbridge import Smartbridge
    bridge = Smartbridge.create_tls(host, KEYFILE, CERTFILE, CAFILE)
    await bridge.connect()
    return bridge


async def _dump(host: str) -> dict:
    bridge = await _connect(host)
    try:
        tree = {
            "areas": bridge.areas,
            "devices": bridge.devices,
            "scenes": bridge.scenes,
            "buttons": getattr(bridge, "buttons", {}),
            "occupancy_groups": getattr(bridge, "occupancy_groups", {}),
        }
        return tree
    finally:
        await bridge.close()


def dump_tree(host: str, as_json: bool = False) -> dict:
    _require_lib()
    tree = asyncio.run(_dump(host))
    if as_json:
        print(json.dumps(tree, indent=2, default=str))
    else:
        _pretty(tree)
    return tree


def _pretty(tree: dict) -> None:
    print("\n=== AREAS ===")
    for aid, a in (tree.get("areas") or {}).items():
        print(f"  [{aid}] {a.get('name')}")
    print("\n=== DEVICES (zones/loads) ===")
    for did, d in (tree.get("devices") or {}).items():
        print(f"  [{did}] {d.get('name')}  type={d.get('type')} "
              f"zone={d.get('zone')} area={d.get('area')}")
    print("\n=== BUTTONS (keypads/picos) ===")
    for bid, b in (tree.get("buttons") or {}).items():
        print(f"  [{bid}] {b}")
    print("\n=== SCENES ===")
    for sid, s in (tree.get("scenes") or {}).items():
        print(f"  [{sid}] {s.get('name')}")


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 3:
        print("usage: python -m savantsniffer.leap <pair|dump> <host>")
        raise SystemExit(2)
    action, host = sys.argv[1], sys.argv[2]
    if action == "pair":
        pair(host)
    elif action == "dump":
        dump_tree(host, as_json="--json" in sys.argv)
    else:
        print("unknown action")
        raise SystemExit(2)
