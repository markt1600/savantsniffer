"""Load/save the human-friendly device map (devices.yaml) and resolve names -> IDs.

Schema (devices.yaml):

  system: LIP            # or LEAP
  processor: 192.168.1.50
  areas:
    kitchen:
      outputs:
        island:   {id: 12, kind: dimmer}      # LIP integration id / LEAP zone
        cans:     {id: 13, kind: switch}
      keypads:
        master keypad:
          id: 25
          buttons:
            1: {label: "all on"}
            3: {label: "movie scene"}

Names are matched case-insensitively; "kitchen island" resolves area 'kitchen'
output 'island'. Ambiguous names raise so we never act on the wrong load.
"""
from __future__ import annotations
import os
from dataclasses import dataclass

import yaml

DEFAULT_PATH = "devices.yaml"


@dataclass
class OutputRef:
    area: str
    name: str
    id: int
    kind: str = "dimmer"


@dataclass
class KeypadRef:
    area: str
    name: str
    id: int
    buttons: dict[int, str]


class DeviceMap:
    def __init__(self, data: dict):
        self.data = data or {}

    @classmethod
    def load(cls, path: str = DEFAULT_PATH) -> "DeviceMap":
        if not os.path.exists(path):
            return cls({"system": None, "processor": None, "areas": {}})
        with open(path) as f:
            return cls(yaml.safe_load(f) or {})

    def save(self, path: str = DEFAULT_PATH) -> None:
        with open(path, "w") as f:
            yaml.safe_dump(self.data, f, sort_keys=False, default_flow_style=False)

    @property
    def system(self) -> str | None:
        return self.data.get("system")

    @property
    def processor(self) -> str | None:
        return self.data.get("processor")

    def areas(self) -> dict:
        return self.data.setdefault("areas", {})

    # --- resolution ---
    def _split(self, phrase: str) -> tuple[str | None, str]:
        """Split 'kitchen island' -> ('kitchen','island') by longest matching area."""
        low = phrase.strip().lower()
        best = None
        for area in self.areas():
            a = area.lower()
            if low == a:
                return area, ""
            if low.startswith(a + " "):
                if best is None or len(a) > len(best.lower()):
                    best = area
        if best:
            return best, phrase[len(best):].strip()
        return None, phrase.strip()

    def resolve_output(self, phrase: str) -> OutputRef:
        area, name = self._split(phrase)
        matches: list[OutputRef] = []
        for aname, adata in self.areas().items():
            if area and aname != area:
                continue
            for oname, odata in (adata.get("outputs") or {}).items():
                target = name if area else phrase
                if oname.lower() == target.strip().lower():
                    matches.append(OutputRef(aname, oname, int(odata["id"]),
                                             odata.get("kind", "dimmer")))
        if not matches:
            raise KeyError(f"no output matching {phrase!r}")
        if len(matches) > 1:
            where = ", ".join(f"{m.area}/{m.name}" for m in matches)
            raise KeyError(f"ambiguous output {phrase!r}: {where}")
        return matches[0]

    def resolve_keypad(self, phrase: str) -> KeypadRef:
        area, name = self._split(phrase)
        matches: list[KeypadRef] = []
        for aname, adata in self.areas().items():
            if area and aname != area:
                continue
            for kname, kdata in (adata.get("keypads") or {}).items():
                target = name if area else phrase
                if kname.lower() == target.strip().lower():
                    btns = {int(k): (v.get("label", "") if isinstance(v, dict) else str(v))
                            for k, v in (kdata.get("buttons") or {}).items()}
                    matches.append(KeypadRef(aname, kname, int(kdata["id"]), btns))
        if not matches:
            raise KeyError(f"no keypad matching {phrase!r}")
        if len(matches) > 1:
            where = ", ".join(f"{m.area}/{m.name}" for m in matches)
            raise KeyError(f"ambiguous keypad {phrase!r}: {where}")
        return matches[0]

    # --- mutation helpers (used while walking the house) ---
    def add_output(self, area: str, name: str, id: int, kind: str = "dimmer") -> None:
        a = self.areas().setdefault(area, {})
        a.setdefault("outputs", {})[name] = {"id": int(id), "kind": kind}

    def add_keypad_button(self, area: str, keypad: str, kp_id: int,
                          button: int, label: str) -> None:
        a = self.areas().setdefault(area, {})
        kp = a.setdefault("keypads", {}).setdefault(keypad, {"id": int(kp_id), "buttons": {}})
        kp["id"] = int(kp_id)
        kp.setdefault("buttons", {})[int(button)] = {"label": label}

    def add_button(self, area: str, keypad: str, kp_id: int, button: int,
                   label: str = "", kind: str = "output",
                   effect: dict | None = None) -> None:
        """Record a keypad button and its type.

        kind: 'output'      -> controls one load
              'macro'       -> fires a scene / burst of loads (effect = {id: level})
              'integration' -> triggers something outside Lutron (Savant/Spotify);
                               effect stays empty and is captured Savant-side.
        """
        a = self.areas().setdefault(area, {})
        kp = a.setdefault("keypads", {}).setdefault(keypad, {"id": int(kp_id), "buttons": {}})
        kp["id"] = int(kp_id)
        entry = {"label": label, "kind": kind}
        if kind == "macro" and effect:
            entry["effect"] = [{"id": int(k), "level": float(v)} for k, v in effect.items()]
        if kind == "integration":
            entry["note"] = "effect is outside Lutron; capture via Savant traffic (goal 8)"
        kp.setdefault("buttons", {})[int(button)] = entry

    def merge_seed(self, seed: dict) -> dict:
        """Merge a scaffold (e.g. from layout.seed.yaml) into this map.

        Adds missing areas / keypads / buttons. NEVER overwrites a value already
        present (a real id, button number, or captured effect stays put), so you
        can re-run it safely as you fill things in during sniffing.
        Returns a summary of what was added.
        """
        added = {"areas": 0, "keypads": 0, "buttons": 0}
        for k in ("system", "processor", "source"):
            if seed.get(k) and not self.data.get(k):
                self.data[k] = seed[k]
        for aname, adata in (seed.get("areas") or {}).items():
            area = self.areas().setdefault(aname, {})
            if aname not in self.data["areas"] or area == {}:
                added["areas"] += 1
            for kname, kdata in (adata.get("keypads") or {}).items():
                kps = area.setdefault("keypads", {})
                if kname not in kps:
                    kps[kname] = {"id": kdata.get("id"), "buttons": {}}
                    added["keypads"] += 1
                kp = kps[kname]
                for bkey, bdata in (kdata.get("buttons") or {}).items():
                    btns = kp.setdefault("buttons", {})
                    if bkey not in btns:
                        btns[bkey] = dict(bdata)
                        added["buttons"] += 1
                    else:
                        # fill only missing sub-fields, keep captured values
                        for f, v in bdata.items():
                            btns[bkey].setdefault(f, v)
        return added

    def all_outputs(self) -> list[OutputRef]:
        out = []
        for aname, adata in self.areas().items():
            for oname, odata in (adata.get("outputs") or {}).items():
                out.append(OutputRef(aname, oname, int(odata["id"]), odata.get("kind", "dimmer")))
        return out

    def all_keypads(self) -> list[KeypadRef]:
        out = []
        for aname, adata in self.areas().items():
            for kname, kdata in (adata.get("keypads") or {}).items():
                btns = {int(k): (v.get("label", "") if isinstance(v, dict) else str(v))
                        for k, v in (kdata.get("buttons") or {}).items()}
                out.append(KeypadRef(aname, kname, int(kdata["id"]), btns))
        return out
