"""High-level control on top of the device map. State-changing calls are gated.

Every method that changes lights/shades/scenes takes confirm=True and, per your
observe-first rule, the CLI/web layer must obtain a fresh yes each time until you
say otherwise.
"""
from __future__ import annotations
from dataclasses import dataclass

from .devicemap import DeviceMap
from .lip import LIPClient


class NotArmed(Exception):
    pass


@dataclass
class Controller:
    dmap: DeviceMap
    client: LIPClient | None = None   # reuse a live session instead of opening a 2nd one

    def _send(self, cmd: str) -> None:
        """Send a gated command over the live client if given, else a short session.

        Never opens a second session while a live one is supplied, honouring the
        processor's small integration-session pool.
        """
        if self.client is not None:
            self.client.arm_control(True)
            try:
                self.client.send_control(cmd)
            finally:
                self.client.arm_control(False)
            return
        with self._client() as c:
            c.arm_control(True)
            c.send_control(cmd)

    def _client(self) -> LIPClient:
        env = _env()
        host = self.dmap.processor or env.get("LUTRON_HOST")
        if not host:
            raise RuntimeError("no processor host in devices.yaml or LUTRON_HOST")
        return LIPClient(
            host=host,
            port=int(env.get("LUTRON_LIP_PORT", 23)),
            username=env.get("LUTRON_LIP_USER", "lutron"),
            password=env.get("LUTRON_LIP_PASSWORD", "integration"),
        )

    # --- read-only ---
    def query(self, output_phrase: str) -> str:
        ref = self.dmap.resolve_output(output_phrase)
        return f"?OUTPUT,{ref.id},1  ({ref.area}/{ref.name})"

    def preview_set(self, output_phrase: str, level: float) -> str:
        ref = self.dmap.resolve_output(output_phrase)
        return f"#OUTPUT,{ref.id},1,{level:g}  -> {ref.area}/{ref.name} to {level:g}%"

    def preview_press(self, keypad_phrase: str, button: int) -> str:
        ref = self.dmap.resolve_keypad(keypad_phrase)
        label = ref.buttons.get(button, "")
        return f"#DEVICE,{ref.id},{button},3  -> press {ref.area}/{ref.name} button {button} {label}".rstrip()

    # --- state-changing (require confirm=True each call) ---
    def set_level(self, output_phrase: str, level: float, confirm: bool) -> str:
        if not confirm:
            raise NotArmed("set_level requires confirm=True (observe-first policy)")
        ref = self.dmap.resolve_output(output_phrase)
        cmd = f"#OUTPUT,{ref.id},1,{level:g}"
        self._send(cmd)
        return cmd

    def press(self, keypad_phrase: str, button: int, confirm: bool) -> str:
        if not confirm:
            raise NotArmed("press requires confirm=True (observe-first policy)")
        ref = self.dmap.resolve_keypad(keypad_phrase)
        cmd = f"#DEVICE,{ref.id},{button},3"
        self._send(cmd)
        return cmd


def _env() -> dict:
    import os
    try:
        from dotenv import dotenv_values
        vals = dict(dotenv_values(".env"))
    except Exception:
        vals = {}
    for k, v in os.environ.items():
        vals.setdefault(k, v)
    return vals
