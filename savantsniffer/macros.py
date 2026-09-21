"""Macro capture.

A keypad button can be one of three things:
  * output   — directly controls one load (simple dimmer/switch).
  * macro    — a scene/macro that fires a BURST of ~OUTPUT changes across many
               loads (e.g. "home off"). We capture the burst and record the
               resulting load levels as the macro's effect set.
  * integration — triggers something OUTSIDE Lutron (e.g. Savant plays a Spotify
               playlist). No ~OUTPUT follows on the Lutron side; the effect lives
               in the Savant traffic (see capture.py / goal 8). We record the
               button as an integration and note it for Savant-side capture.

MacroRecorder groups events that arrive shortly after a trigger. Feed it every
monitored event; call begin() right before you press the physical button, then
finish() after the burst settles.
"""
from __future__ import annotations
import time
from dataclasses import dataclass, field


@dataclass
class MacroStep:
    output_id: int
    level: float
    ts: float


@dataclass
class MacroCapture:
    trigger_device: int | None = None
    trigger_button: int | None = None
    steps: list[MacroStep] = field(default_factory=list)
    started: float = field(default_factory=time.monotonic)

    def add_output(self, output_id: int, level: float) -> None:
        self.steps.append(MacroStep(output_id, level, time.monotonic()))

    def classify(self) -> str:
        """Guess the button type from what we captured."""
        ids = {s.output_id for s in self.steps}
        if not ids:
            return "integration"   # nothing on Lutron -> likely Savant/Spotify etc.
        if len(ids) == 1:
            return "output"
        return "macro"

    def effect_set(self) -> dict[int, float]:
        """Final level per output (last value wins)."""
        out: dict[int, float] = {}
        for s in self.steps:
            out[s.output_id] = s.level
        return out


class MacroRecorder:
    """Stateful helper the monitor/web layer drives while walking the house."""
    def __init__(self, settle_seconds: float = 2.5):
        self.settle = settle_seconds
        self.active: MacroCapture | None = None
        self._last_event = 0.0

    def begin(self, device: int | None = None, button: int | None = None) -> None:
        self.active = MacroCapture(trigger_device=device, trigger_button=button)
        self._last_event = time.monotonic()

    def feed(self, raw: str) -> None:
        if self.active is None:
            return
        if raw.startswith("~OUTPUT"):
            parts = raw.split(",")
            if len(parts) >= 4:
                try:
                    self.active.add_output(int(parts[1]), float(parts[3]))
                    self._last_event = time.monotonic()
                except ValueError:
                    pass
        elif raw.startswith("~DEVICE"):
            parts = raw.split(",")
            # capture which button triggered it, if we didn't know
            if self.active.trigger_device is None and len(parts) >= 3:
                try:
                    self.active.trigger_device = int(parts[1])
                    self.active.trigger_button = int(parts[2])
                except ValueError:
                    pass
            self._last_event = time.monotonic()

    def settled(self) -> bool:
        return self.active is not None and (time.monotonic() - self._last_event) > self.settle

    def finish(self) -> MacroCapture | None:
        cap = self.active
        self.active = None
        return cap
