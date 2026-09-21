# savantsniffer

Local, **observe-first** tooling to discover and take local control of a Lutron
lighting system driven by a Savant host (Mac mini) — a system **you own** — when
you have no programming files, integration report, or credentials.

It runs entirely on your own machine and talks only to your own LAN. Nothing here
modifies your Lutron processor or your Savant host.

## Safety model (built in, not optional)

- **Observe first.** Nothing changes a light, shade, or scene unless you explicitly
  confirm it — every time — via the confirm box (web) or the `[y/N]` prompt (CLI).
  The monitor is read-only; it only turns on event *reporting*.
- **No config changes.** There is no code path that writes programming, firmware,
  factory resets, or settings to the Lutron processor or the Mac mini.
- **One connection, closed cleanly.** The Lutron processor allows only a few
  integration sessions. The client holds a single connection and always closes it,
  so it never knocks Savant off.
- **Local subnet only.** Discovery auto-detects your `/24` and always shows you the
  exact scan command before running it. You approve it first.
- **Secrets stay local.** Discovered credentials go in `.env`, which is git-ignored.
  Captures and logs are git-ignored too.

## Install

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e .            # or: pip install -r requirements.txt
pip install -e ".[leap]"    # only if you have a LEAP system (QSX / RA3 / Caseta)
cp .env.example .env        # fill in as you discover things
```

This gives you two commands: `lutron` (CLI) and `savantsniffer-web` (the web UI).

## The workflow, step by step

### 0. If you use the Mac app: open the Guide
The native app's Guide screen walks these same steps in order and checks them off
from real state. The CLI below is the same workflow by hand.

### 1. Discover the Lutron processor and the Savant Mac mini
```bash
lutron doctor        # what discovery tools exist on your OS (installs nothing)
lutron discover      # shows the scan command, asks, then scans your subnet
```
It classifies hosts by MAC vendor: **Lutron** rows are candidate processors,
**Apple** rows are candidate Mac minis. If `arp-scan`/`nmap` aren't installed,
`doctor` tells you the install command for your OS — you install it, not the tool.

### 2. Port-check and identify the system
```bash
lutron portcheck 192.168.1.50
```
- Port **23** open → **LIP / telnet** (HomeWorks QS or RadioRA 2). Go to step 3.
- Port **8081/8083** open → **LEAP / TLS** (HomeWorks QSX, RadioRA 3, Caseta). Go to step 5.

### 3. LIP: monitor and walk the house
```bash
lutron monitor 192.168.1.50           # or set LUTRON_HOST in .env and omit it
```
Logs in with the credentials from `.env` (default `lutron`/`integration`), enables
`#MONITORING,3,1` and `#MONITORING,5,1`, and appends every `~DEVICE`/`~OUTPUT`
event with timestamps to `logs/monitor-*.log`. Walk the house pressing buttons and
calling out room names. Ctrl-C closes the session cleanly.

Prefer the **web UI** for this — it lets you label events as they arrive:
```bash
savantsniffer-web      # open http://127.0.0.1:8765
```

### 4. If the default login fails: recover credentials from your own traffic
Because LIP telnet is plaintext, the username/password the Savant host sends to the
processor are readable in a capture of your own network:
```bash
python -m savantsniffer.capture   # (helper functions; see below)
```
Two capture paths, chosen for your network:
- **UniFi / managed switch:** mirror (SPAN) the Mac mini's switch port to your
  laptop's port, then capture telnet to the processor.
- **tcpdump on the Mac mini** (read-only, changes nothing) if you have shell.

Build the command and parse the result:
```python
from savantsniffer.capture import tcpdump_command, tshark_follow_command, extract_credentials
print(tcpdump_command("en0", "192.168.1.50"))          # capture
print(tshark_follow_command("captures/lutron.pcap"))   # reassemble to text
# then:
creds = extract_credentials(open("stream.txt").read()) # pulls login/password
```
LEAP (8081) is TLS — you can't read creds from it; use pairing (step 5) instead.

### 5. LEAP: pair and dump the tree
```bash
lutron leap-pair 192.168.1.50   # press the pairing button on the bridge/processor
lutron leap-dump 192.168.1.50   # full area / device / button / zone tree
```
Pairing writes `caseta.key` / `caseta.crt` / `caseta-bridge.crt` locally.

### Starting scaffold from the button schedule
If you have the dealer's button-function schedule (like `LUTRON_20231108_rev`), its
contents are pre-loaded as `layout.seed.yaml`: 21 rooms, ~130 buttons, each tagged
by type (output / macro-scene / integration / hvac / shade / fan / rgb / dim) with
the intended behavior and as-built status. Merge it into your live map:
```bash
lutron seed            # or click "Load starting layout" in the web UI
```
This gives you every keypad and button label up front. The real **integration id**
and **button number** are still `null` until you sniff them — as you walk the house,
each `~DEVICE`/`~OUTPUT` event fills them in. `seed` is idempotent and never
overwrites a value you've already captured, so re-run it any time.

Button types tell you where each effect lives:
- **output / macro / shade / hvac / fan / rgb / dim** — Lutron. Captured from
  `~OUTPUT` events (a macro like "Home Off" captures the whole burst).
- **integration** ("Music", "Broadcast", volume, lift) — outside Lutron, on the
  Savant side. The button press shows as `~DEVICE`, but the effect (Spotify, AV)
  is captured from Savant traffic in step 8.

### 6. Build the device map

As you monitor, label each event with its room and function. In the web UI, click an
event → give it a room + name → it's written into `devices.yaml` with the right
integration id / button number. See `devices.example.yaml` for the format.

### 7. Control from names
```bash
lutron list                          # what's mapped
lutron set "kitchen island" 50       # asks before changing anything
lutron set "kitchen island" 20 --fade 2   # ramp to 20% over 2 seconds
lutron press "master keypad" 3       # asks before pressing
```
Dimmers accept an optional fade time, so a scene the dealer programmed at 50%
with a quick ramp can become your own at 20% with whatever fade you like.

### Export everything you've learned
```bash
lutron export --out integration-report.md
```
Writes a Markdown report with the processor, system, credentials, a protocol
cheat sheet, every keypad and button with its exact `#DEVICE` command, every
load with its `#OUTPUT`/`?OUTPUT` commands, captured scene effects, and your
custom scenes. Future apps read this instead of re-testing. It contains
credentials, so keep it out of git (the default name is ignored).

### Audio zones and other Savant-side effects
Some buttons drive audio (e.g. office lights on → office audio on; Broadcast →
several zones). Lutron only reports the keypad press; Savant hears that press
and commands the audio hardware itself. To map the zones:
```bash
# 1. capture the Savant host's traffic while you press the buttons (monitor running)
sudo tcpdump -i en0 -s 0 -w savant.pcap 'host <savant-ip>'
# 2. export the packets as text
tshark -r savant.pcap -Y 'ip.src==<savant-ip>' -T fields -E separator=/t \
  -e frame.time_epoch -e ip.dst -e tcp.dstport -e udp.dstport -e tcp.payload -e udp.payload > savant.txt
# 3. line each press up with what Savant sent in the next 2 seconds
lutron correlate --savant savant.txt --monitor-log logs/monitor-*.log --out zones.md
```
The result lists, per press, which device and port Savant talked to and the
command bytes. Note which zones came on and record them on the button. Plain-TCP
commands can be replayed as Savant steps in a custom scene; encrypted or
session-bound protocols can be identified but not replayed.

### Macro and integration buttons
Some buttons do more than one thing:
- **Macro** (e.g. "home off") fires a burst of `~OUTPUT` changes across many loads.
  In the web UI: **Arm capture → press the physical button → watch the burst → save**.
  The full effect set (each load's resulting level) is stored under that button.
- **Integration** (e.g. "music" → a Spotify playlist) produces **no** Lutron output;
  the effect lives in the Savant host's traffic. savantsniffer records the button as
  an `integration` and flags it for Savant-side capture.

### 8. Later: Savant → AV / IP device traffic (optional)
Capture what the Savant host sends when you use the Savant app (same mirroring/tcpdump
approach as step 4, but watch the AV/receiver/streamer IPs). This reveals plain-TCP
control protocols you could drive directly. The integration-button notes from step 7
tell you which effects to look for.

## How button presses are told apart from everything else
The monitor is not a packet sniffer. It logs in to the Lutron processor over
telnet the same way an integration app does and receives only Lutron's own event
feed. Within that feed every line is self-describing: `~DEVICE,<keypad>,<button>,<action>`
is a keypad event (action 3 = press, 4 = release) and `~OUTPUT,<id>,1,<level>` is a
load changing level. Everything else (prompts, echoes, acknowledgements) is
dropped. Cameras, streaming and other computers never enter this path at all.
Packet capture is used only for credential recovery and Savant-side effects, and
those captures are filtered by IP before anything is written.

## Layout
```
savantsniffer/
  osdetect.py    OS + tool detection (installs nothing)
  discovery.py   LAN scan command builder + parsers + MAC vendor match
  portcheck.py   port probe + system identification
  lip.py         LIP telnet client + monitor logger (single, clean session)
  macros.py      macro / integration burst capture
  leap.py        pylutron-caseta pairing + tree dump
  devicemap.py   devices.yaml load/save + name→id resolution
  controller.py  gated set/press (with fade) on top of the map
  capture.py     credential-capture guidance + telnet stream parser
  report.py      the integration report (lutron export)
  correlate.py   press ↔ Savant-traffic correlation (audio zones, AV)
  cli.py         the `lutron` command
  webapp.py      the local web UI (Flask, 127.0.0.1 only)
tests/           pure-logic tests (no hardware needed)
```

## Tests
```bash
python -m pytest tests/ -q
```
Cover the OUI/vendor matching, scan-output parsers, port→system logic, event
parsing, name resolution (including ambiguity), macro classification, and
credential extraction — all without touching hardware.
