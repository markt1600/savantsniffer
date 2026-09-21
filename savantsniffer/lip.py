"""Lutron Integration Protocol (LIP) telnet client + monitor logger.

Used for HomeWorks QS / RadioRA 2 (plaintext telnet, port 23).

Safety model baked in:
  * ONE connection at a time. Always closed cleanly (context manager) so we never
    leave a stray session that could knock Savant off the processor's small pool.
  * enable_monitoring() only turns on event *reporting* (#MONITORING). It does not
    change any load, shade, or scene.
  * Any state-changing command must go through send_control(), which raises unless
    explicitly armed by the caller. The monitor never calls it.
"""
from __future__ import annotations
import datetime as _dt
import socket
import time
from dataclasses import dataclass

LOGIN_PROMPT = b"login:"
PASSWORD_PROMPT = b"password:"
READY_PROMPTS = (b"QNET>", b"GNET>", b"QSE>")

# System identity inferred from the ready prompt.
PROMPT_SYSTEM = {
    "QNET>": "HomeWorks QS",
    "GNET>": "RadioRA 2",
    "QSE>":  "HomeWorks QS (QSE)",
}


class LIPError(Exception):
    pass


class LIPAuthError(LIPError):
    pass


@dataclass
class MonitorEvent:
    ts: _dt.datetime
    raw: str

    @property
    def kind(self) -> str:
        if self.raw.startswith("~DEVICE"):
            return "DEVICE"
        if self.raw.startswith("~OUTPUT"):
            return "OUTPUT"
        if self.raw.startswith("~"):
            return self.raw[1:].split(",", 1)[0]
        return "OTHER"

    def format(self) -> str:
        return f"{self.ts.isoformat(timespec='milliseconds')}  {self.raw}"


class LIPClient:
    def __init__(self, host: str, port: int = 23,
                 username: str = "lutron", password: str = "integration",
                 timeout: float = 5.0):
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.timeout = timeout
        self.sock: socket.socket | None = None
        self.prompt: str | None = None
        self.system: str | None = None
        self._buf = b""
        self._allow_control = False

    # --- lifecycle ---
    def __enter__(self) -> "LIPClient":
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock.settimeout(self.timeout)
        self._login()

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self.sock.close()
            finally:
                self.sock = None

    # --- low level IO ---
    def _read_until(self, tokens: tuple[bytes, ...], deadline: float) -> bytes:
        while True:
            for tok in tokens:
                idx = self._buf.find(tok)
                if idx != -1:
                    end = idx + len(tok)
                    chunk, self._buf = self._buf[:end], self._buf[end:]
                    return chunk
            if time.monotonic() > deadline:
                raise LIPError(f"timeout waiting for {tokens!r}; got {self._buf!r}")
            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not data:
                raise LIPError("connection closed by processor")
            self._buf += data

    def _login(self) -> None:
        deadline = time.monotonic() + self.timeout * 3
        self._read_until((LOGIN_PROMPT,), deadline)
        self.sock.sendall(self.username.encode() + b"\r\n")
        self._read_until((PASSWORD_PROMPT,), deadline)
        self.sock.sendall(self.password.encode() + b"\r\n")
        # Success -> a ready prompt. Failure -> another 'login:' prompt.
        got = self._read_until(READY_PROMPTS + (LOGIN_PROMPT,), deadline + self.timeout)
        for p in READY_PROMPTS:
            if got.endswith(p):
                self.prompt = p.decode()
                self.system = PROMPT_SYSTEM.get(self.prompt, "Lutron LIP")
                return
        raise LIPAuthError("login rejected (got another login prompt) — default credentials likely wrong")

    def send_raw(self, line: str) -> None:
        if self.sock is None:
            raise LIPError("not connected")
        self.sock.sendall(line.encode() + b"\r\n")

    # --- read-only / observe ---
    def enable_monitoring(self) -> None:
        """Turn on device (keypad) and output (load) event reporting. Does not change loads."""
        self.send_raw("#MONITORING,3,1")   # device/button events -> ~DEVICE
        self.send_raw("#MONITORING,5,1")   # output/zone level events -> ~OUTPUT
        time.sleep(0.3)
        self._drain()

    def query_output(self, integration_id: int) -> None:
        """Ask the processor to report a load's current level (read-only ?OUTPUT)."""
        self.send_raw(f"?OUTPUT,{integration_id},1")

    def _drain(self) -> None:
        try:
            self.sock.settimeout(0.2)
            while True:
                data = self.sock.recv(4096)
                if not data:
                    break
                self._buf += data
        except socket.timeout:
            pass
        finally:
            self.sock.settimeout(self.timeout)

    def read_events(self):
        """Yield MonitorEvent objects as lines arrive. Blocks; stop by breaking/closing."""
        self.sock.settimeout(1.0)
        pending = self._buf
        self._buf = b""
        while True:
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                text = line.decode(errors="replace").strip("\r\x00 ")
                # strip any echoed ready prompt
                for p in READY_PROMPTS:
                    ps = p.decode()
                    if text.startswith(ps):
                        text = text[len(ps):].strip()
                if text:
                    yield MonitorEvent(ts=_dt.datetime.now(), raw=text)
            try:
                data = self.sock.recv(4096)
                if not data:
                    raise LIPError("connection closed by processor")
                pending += data
            except socket.timeout:
                continue

    # --- state-changing (GATED) ---
    def arm_control(self, confirm: bool) -> None:
        """Explicitly allow send_control(). Caller must pass confirm=True per policy."""
        self._allow_control = bool(confirm)

    def send_control(self, line: str) -> None:
        """Send a state-changing command (e.g. #OUTPUT,... / #DEVICE,...). Gated."""
        if not self._allow_control:
            raise LIPError("control is disarmed; call arm_control(True) first (observe-first policy)")
        if not (line.startswith("#OUTPUT") or line.startswith("#DEVICE")):
            raise LIPError(f"refusing non-control-shaped command via send_control: {line!r}")
        self.send_raw(line)


def monitor_to_file(client: LIPClient, logpath: str, kinds=("DEVICE", "OUTPUT"),
                    echo=None) -> None:
    """Hold the session open and append matching events to logpath with timestamps.

    echo: optional callable(str) for live display (e.g. print).
    """
    client.enable_monitoring()
    with open(logpath, "a", buffering=1) as f:
        f.write(f"# --- monitor start {_dt.datetime.now().isoformat()} "
                f"system={client.system} prompt={client.prompt} ---\n")
        for ev in client.read_events():
            if ev.kind in kinds:
                line = ev.format()
                f.write(line + "\n")
                if echo:
                    echo(line)
