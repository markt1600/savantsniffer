"""Command-line interface.

Examples:
  lutron doctor                         # OS + tool check
  lutron discover                       # show scan command, ask, then scan LAN
  lutron portcheck 192.168.1.50         # check 23/8081/8083, identify system
  lutron monitor                        # LIP: hold session, log ~DEVICE/~OUTPUT
  lutron leap-pair 192.168.1.50         # LEAP: pair (press bridge button)
  lutron leap-dump 192.168.1.50         # LEAP: dump area/device/button tree
  lutron set "kitchen island" 50        # GATED: asks before changing a load
  lutron press "master keypad" 3        # GATED: asks before pressing a button
  lutron list                           # show mapped outputs/keypads

Observe-first: `set` and `press` prompt for confirmation every time unless --yes.
"""
from __future__ import annotations
import argparse
import datetime as _dt
import os
import sys

from . import osdetect, discovery, portcheck
from .devicemap import DeviceMap
from .controller import Controller


def _load_env():
    try:
        from dotenv import load_dotenv
        load_dotenv()
    except Exception:
        pass


def cmd_doctor(args):
    info = osdetect.detect()
    print(f"OS: {info.pretty}")
    for t in info.tools.values():
        mark = "OK" if t.present else "--"
        line = f"  [{mark}] {t.name}"
        if not t.present and t.install_hint:
            line += f"   install: {t.install_hint}"
        print(line)
    print(f"\nPreferred discovery tool: {osdetect.preferred_scanner(info) or 'none'}")
    print("Nothing was installed. Install a missing tool yourself if you want it.")


def cmd_discover(args):
    info = osdetect.detect()
    plan = discovery.build_scan_command(subnet=args.subnet, info=info)
    print(f"Detected OS: {info.pretty}")
    print(f"Subnet: {plan.subnet}")
    print(f"Tool:   {plan.tool}   ({plan.note})")
    print("\nAbout to run (LOCAL SUBNET ONLY):\n")
    print("    " + plan.shown + "\n")
    if not args.yes:
        ans = input("Run this scan now? [y/N] ").strip().lower()
        if ans not in ("y", "yes"):
            print("Aborted. (Nothing was scanned.)")
            return
    try:
        hosts, raw = discovery.run_scan(plan)
    except FileNotFoundError:
        print(f"'{plan.tool}' not found. Run `lutron doctor` for install hints.")
        return
    buckets = discovery.classify_hosts(hosts)
    for label in ("Lutron", "Apple", "unknown"):
        rows = buckets.get(label) or []
        if not rows:
            continue
        print(f"\n{label}:")
        for h in rows:
            print(f"  {h.ip:<16} {h.mac:<18} {h.vendor}")
    print("\nMatch the Lutron row to your processor and the Apple row to the Savant Mac mini.")


def cmd_portcheck(args):
    rep = portcheck.probe(args.host)
    print(f"Port check {args.host}:")
    for r in rep.results:
        state = "OPEN " if r.open else "closed"
        print(f"  {r.port:>5}  {state}  {portcheck.PORTS.get(r.port,'')}  {r.detail}")
    label, why = rep.likely_system()
    print(f"\nLikely system: {label}\n  {why}")


def cmd_monitor(args):
    from .lip import LIPClient, monitor_to_file
    env = _env_dict()
    host = args.host or env.get("LUTRON_HOST")
    if not host:
        print("No host. Pass one or set LUTRON_HOST in .env.")
        return
    logpath = args.out or f"logs/monitor-{_dt.datetime.now():%Y%m%d-%H%M%S}.log"
    print(f"Connecting to {host}:{env.get('LUTRON_LIP_PORT', 23)} ...")
    try:
        with LIPClient(host,
                       port=int(env.get("LUTRON_LIP_PORT", 23)),
                       username=env.get("LUTRON_LIP_USER", "lutron"),
                       password=env.get("LUTRON_LIP_PASSWORD", "integration")) as c:
            print(f"Logged in. System: {c.system}  Prompt: {c.prompt}")
            print(f"Monitoring enabled. Logging ~DEVICE/~OUTPUT to {logpath}")
            print("Walk the house pressing buttons; call out room names. Ctrl-C to stop.\n")
            monitor_to_file(c, logpath, echo=print)
    except KeyboardInterrupt:
        print("\nStopped. Session closed cleanly.")
    except Exception as e:
        print(f"Error: {e}")


def cmd_leap_pair(args):
    from . import leap
    leap.pair(args.host)


def cmd_leap_dump(args):
    from . import leap
    leap.dump_tree(args.host, as_json=args.json)


def cmd_list(args):
    dmap = DeviceMap.load(args.map)
    print(f"System: {dmap.system}   Processor: {dmap.processor}")
    print("\nOutputs:")
    for o in dmap.all_outputs():
        print(f"  {o.area}/{o.name:<16} id={o.id} ({o.kind})")
    print("\nKeypads:")
    for k in dmap.all_keypads():
        print(f"  {k.area}/{k.name} id={k.id}")
        for bn, lbl in sorted(k.buttons.items()):
            print(f"      button {bn}: {lbl}")


def cmd_seed(args):
    import yaml
    if not os.path.exists(args.seed):
        print(f"seed file not found: {args.seed}")
        return
    with open(args.seed) as f:
        seed = yaml.safe_load(f)
    dmap = DeviceMap.load(args.map)
    added = dmap.merge_seed(seed)
    dmap.save(args.map)
    print(f"Merged {args.seed} -> {args.map}")
    print(f"  added areas={added['areas']} keypads={added['keypads']} buttons={added['buttons']}")
    print("Existing captured ids/effects were preserved. Fill button/id fields as you sniff.")


def _confirm(preview: str, yes: bool) -> bool:
    print("This will CHANGE hardware state:")
    print("    " + preview)
    if yes:
        return True
    return input("Proceed? [y/N] ").strip().lower() in ("y", "yes")


def cmd_set(args):
    _load_env()
    ctl = Controller(DeviceMap.load(args.map))
    try:
        preview = ctl.preview_set(args.name, args.level)
    except KeyError as e:
        print(f"{e}")
        return
    if not _confirm(preview, args.yes):
        print("Cancelled. Nothing sent.")
        return
    sent = ctl.set_level(args.name, args.level, confirm=True)
    print(f"Sent: {sent}")


def cmd_press(args):
    _load_env()
    ctl = Controller(DeviceMap.load(args.map))
    try:
        preview = ctl.preview_press(args.name, args.button)
    except KeyError as e:
        print(f"{e}")
        return
    if not _confirm(preview, args.yes):
        print("Cancelled. Nothing sent.")
        return
    sent = ctl.press(args.name, args.button, confirm=True)
    print(f"Sent: {sent}")


def _env_dict() -> dict:
    import os
    _load_env()
    return dict(os.environ)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="lutron", description="Local Lutron/Savant control (observe-first).")
    p.add_argument("--map", default="devices.yaml", help="device map path")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="OS + tool availability").set_defaults(func=cmd_doctor)

    sp = sub.add_parser("discover", help="scan LAN for Lutron + Apple hosts")
    sp.add_argument("--subnet", help="e.g. 192.168.1.0/24 (auto-detected if omitted)")
    sp.add_argument("--yes", action="store_true", help="skip the confirm prompt")
    sp.set_defaults(func=cmd_discover)

    sp = sub.add_parser("portcheck", help="check 23/8081/8083 and identify system")
    sp.add_argument("host")
    sp.set_defaults(func=cmd_portcheck)

    sp = sub.add_parser("monitor", help="LIP: hold session, log ~DEVICE/~OUTPUT")
    sp.add_argument("host", nargs="?")
    sp.add_argument("--out", help="log file path")
    sp.set_defaults(func=cmd_monitor)

    sp = sub.add_parser("leap-pair", help="LEAP: pair with bridge (press button)")
    sp.add_argument("host")
    sp.set_defaults(func=cmd_leap_pair)

    sp = sub.add_parser("leap-dump", help="LEAP: dump area/device/button tree")
    sp.add_argument("host")
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_leap_dump)

    sub.add_parser("list", help="show mapped outputs/keypads").set_defaults(func=cmd_list)

    sp = sub.add_parser("seed", help="merge layout.seed.yaml scaffold into devices.yaml")
    sp.add_argument("--seed", default="layout.seed.yaml")
    sp.set_defaults(func=cmd_seed)

    sp = sub.add_parser("set", help='set a load level, e.g. set "kitchen island" 50')
    sp.add_argument("name")
    sp.add_argument("level", type=float)
    sp.add_argument("--yes", action="store_true", help="skip confirm (only after you say so)")
    sp.set_defaults(func=cmd_set)

    sp = sub.add_parser("press", help='press a keypad button, e.g. press "master keypad" 3')
    sp.add_argument("name")
    sp.add_argument("button", type=int)
    sp.add_argument("--yes", action="store_true", help="skip confirm (only after you say so)")
    sp.set_defaults(func=cmd_press)

    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
