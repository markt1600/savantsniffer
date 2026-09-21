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
  Models.swift             data models, capture status, custom-macro types
  Discovery.swift          LAN scan (runs system tools) + OUI classification
  PortCheck.swift          TCP port probe + LIP/LEAP identification
  LIPClient.swift          telnet client over Network.framework (observe-first)
  DeviceStore.swift        device map load/save, coverage, scene runner
  Keychain.swift           stores the Lutron password locally
  Views/                   Coverage, Discover, PortCheck, Monitor, Scenes,
                           Control, Map, Credentials/LEAP, sheets
  Resources/layout.seed.json   the 21-room / ~130-button scaffold
```
