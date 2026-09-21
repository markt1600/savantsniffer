"""LEAP support (HomeWorks QSX / RadioRA 3 / RA2 Select / Caseta).

Thin wrapper over leap_bridge.py so the package CLI keeps working:
  python3 -m savantsniffer.leap pair  <host>
  python3 -m savantsniffer.leap dump  <host> [--json]
  python3 -m savantsniffer.leap serve <host>
Certificates live in ~/Library/Application Support/SavantSniffer/leap by default
(override with --dir), the same place the Mac app uses, so pairing once serves both.
"""
from __future__ import annotations
import json
import sys

from . import leap_bridge


def pair(host: str, d: str | None = None) -> int:
    return leap_bridge.main(["pair", host] + (["--dir", d] if d else []))


def dump_tree(host: str, as_json: bool = False, d: str | None = None) -> int:
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = leap_bridge.main(["tree", host] + (["--dir", d] if d else []))
    text = buf.getvalue().strip()
    if as_json or rc != 0:
        print(text)
        return rc
    tree = json.loads(text.splitlines()[-1])
    print("\n=== AREAS ===")
    for a in tree["areas"]:
        print(f"  [{a['id']}] {a['name']}")
    print("\n=== DEVICES ===")
    for d_ in tree["devices"]:
        print(f"  [{d_['id']}] {d_['name']}  type={d_['type']} area={d_['area']} zone={d_['zone']} level={d_['level']}")
    print("\n=== BUTTONS ===")
    for b in tree["buttons"]:
        print(f"  [{b['id']}] device {b['parent']} button {b['number']}  {b['name']}")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        raise SystemExit(2)
    action, host = args[0], args[1]
    d = None
    if "--dir" in args:
        d = args[args.index("--dir") + 1]
    if action == "pair":
        raise SystemExit(pair(host, d))
    if action == "dump":
        raise SystemExit(dump_tree(host, "--json" in args, d))
    if action == "serve":
        raise SystemExit(leap_bridge.main(["serve", host] + (["--dir", d] if d else [])))
    print("unknown action"); raise SystemExit(2)
