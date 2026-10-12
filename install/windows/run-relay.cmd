@echo off
rem Starts the Lutron relay from its private environment. Used by the
rem "LutronRelay" scheduled task; double-click it to run by hand.
set RELAY_HOME=%LOCALAPPDATA%\LutronRelay
cd /d "%RELAY_HOME%"
"%RELAY_HOME%\venv\Scripts\python.exe" -m savantsniffer relay --config "%RELAY_HOME%\relay.yaml" >> "%RELAY_HOME%\relay-console.log" 2>&1
