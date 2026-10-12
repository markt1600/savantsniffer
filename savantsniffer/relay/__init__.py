"""The relay: one always-on process that holds the single LEAP connection to the
Lutron processor and lets every other device on the LAN talk to it over HTTP.

    lutron relay            # start (reads/creates relay.yaml next to devices.yaml)

See core.py for the engine and server.py for the HTTP API + dashboard.
"""
