# SavantSniffer — native macOS app

A SwiftUI front end for the same observe-first workflow as the Python toolkit:
discover the Lutron processor and Savant host, port-check, monitor keypad/load
events live, label them, capture macro bursts, track capture coverage with
green lights, and build your own custom scenes.

## Requirements
- macOS 13 or later
- Xcode 15 or later

## Run it
```bash
cd macapp
open Package.swift        # opens the package in Xcode
```
In Xcode, pick the **SavantSniffer** scheme and press Run (Cmd-R). Or from the
terminal:
```bash
cd macapp
swift run
```

The app is a local developer tool and is intentionally **not sandboxed**: it runs
`arp`/`nmap` for discovery, opens TCP sockets to the Lutron processor, and stores
the Lutron password in your login Keychain. It writes its device map and logs to
`~/Library/Application Support/SavantSniffer/`.

## Screens
- **Coverage**: progress ring, captured/partial/pending tiles, the four things you
  need (processor, system, access, Savant host), and one card per room with a dot
  per button. Click a room to expand. **Export report…** writes a Markdown
  integration report (credentials, cheat sheet, every button's command, loads,
  scenes) with the JSON map beside it.
- **Discover / Port check**: find the processor and Savant host, identify LIP vs
  LEAP. Privileged scans run through the native macOS admin prompt, so the command
  you approve is the command that runs.
- **Monitor & label**: live event stream with a capture rail. Arm capture, press
  the physical button, watch the burst, name it. Integration buttons take optional
  audio zone / source fields.
- **Custom scenes**: clone a captured button's loads, change levels, add a fade per
  step, add Savant replays or pauses, and see the exact commands before running.
- **Control**: gated single load / single press, with fade.
- **Credentials & LEAP**: copy-paste commands for credential recovery, Savant
  capture + correlation, and LEAP pairing.

## What's native vs. Python
- **Native in the app:** discovery, port checks, LIP (telnet) monitoring and
  control, labelling, macro capture, coverage dashboard, custom scenes.
- **Still via the Python tool (shown as copy-paste commands in the app):** LEAP
  pairing (QSX / RadioRA 3 / Caseta) and packet-capture credential recovery.

## Safety model
Same as the toolkit: monitoring is read-only; every state-changing action needs an
explicit confirm; a single LIP session is opened and closed cleanly; discovery
shows the exact command before running and scans only your local subnet.

## Layout
```
macapp/Sources/SavantSniffer/
  SavantSnifferApp.swift   app entry + sidebar navigation
  Models.swift             data models, capture status, custom-macro types, macro recorder
  Exporter.swift           Markdown + JSON integration report
  Theme.swift              colours and shared UI pieces (cards, LEDs, chips)
  Discovery.swift          LAN scan (runs system tools) + OUI classification
  PortCheck.swift          TCP port probe + LIP/LEAP identification
  LIPClient.swift          telnet client over Network.framework (observe-first)
  DeviceStore.swift        device map load/save, coverage, scene runner
  Keychain.swift           stores the Lutron password locally
  Views/                   Coverage, Discover, PortCheck, Monitor, Scenes,
                           Control, Map, Credentials/LEAP, sheets
  Resources/layout.seed.json   the 21-room / ~130-button scaffold
```
