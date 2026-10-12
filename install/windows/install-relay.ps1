<#
  Installs the Lutron relay on this Windows PC and makes it start at logon.

  Run from an elevated PowerShell (right-click, "Run as administrator"):
      Set-ExecutionPolicy -Scope Process Bypass
      .\install-relay.ps1 -Processor 192.168.1.201

  What it does, in order:
    1. checks that Python 3.10+ is installed (python.org installer; tick "Add to PATH")
    2. creates a private virtual environment in  %LOCALAPPDATA%\LutronRelay\venv
    3. installs this project plus pylutron-caseta into it
    4. writes %LOCALAPPDATA%\LutronRelay\relay.yaml (processor, port, a fresh token)
       and copies the bundled, pre-filled devices.yaml next to it
    5. opens TCP 8765 on the Windows firewall for the private network profile
    6. registers a Scheduled Task "LutronRelay" that runs the relay at logon

  Afterwards copy the three pairing files from the Mac
      ~/Library/Application Support/SavantSniffer/leap/{caseta.key, caseta.crt, caseta-bridge.crt}
  into  %LOCALAPPDATA%\LutronRelay\leap-certs\   and start the task (or sign out and in).
#>
param(
    [string]$Processor = "192.168.1.201",
    [int]$Port = 8765,
    [string]$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
)
$ErrorActionPreference = "Stop"
$Home_ = Join-Path $env:LOCALAPPDATA "LutronRelay"
$Venv  = Join-Path $Home_ "venv"
$Certs = Join-Path $Home_ "leap-certs"
$Cfg   = Join-Path $Home_ "relay.yaml"

Write-Host "== Lutron relay installer" -ForegroundColor Cyan
Write-Host "   repo:   $RepoDir"
Write-Host "   home:   $Home_"

# 1. python
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { throw "python was not found. Install Python 3.10+ from https://www.python.org/downloads/windows/ and tick 'Add python.exe to PATH', then re-run." }
$ver = & python -c "import sys; print('%d.%d' % sys.version_info[:2])"
if ([version]$ver -lt [version]"3.10") { throw "Python $ver found; 3.10 or newer is needed." }
Write-Host "   python: $ver"

# 2. venv + 3. packages
New-Item -ItemType Directory -Force -Path $Home_, $Certs | Out-Null
if (-not (Test-Path (Join-Path $Venv "Scripts\python.exe"))) { & python -m venv $Venv }
$vpy = Join-Path $Venv "Scripts\python.exe"
& $vpy -m pip install --upgrade pip --quiet
& $vpy -m pip install --quiet -e "$RepoDir" "pylutron-caseta>=0.18.0"
Write-Host "   packages installed"

# 4. config + map
if (-not (Test-Path $Cfg)) {
    $token = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    @"
# savantsniffer relay configuration. The token is the only secret: keep this file private.
processor: $Processor
certs_dir: leap-certs
map_path: devices.yaml
scenes_path: scenes.yaml
log_path: relay.log
bind: 0.0.0.0
port: $Port
token: $token
control_enabled: false
name: lutron-relay
"@ | Set-Content -Path $Cfg -Encoding UTF8
    Write-Host "   wrote $Cfg"
} else { Write-Host "   keeping existing $Cfg" }
$map = Join-Path $Home_ "devices.yaml"
if (-not (Test-Path $map)) {
    Copy-Item (Join-Path $RepoDir "savantsniffer\data\devices.savant.yaml") $map
    Copy-Item (Join-Path $RepoDir "savantsniffer\data\savant_findings.json") (Join-Path $Home_ "savant_findings.json")
    Write-Host "   copied the pre-filled device map"
}

# 5. firewall
if (-not (Get-NetFirewallRule -DisplayName "Lutron Relay" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Lutron Relay" -Direction Inbound -Protocol TCP -LocalPort $Port -Profile Private -Action Allow | Out-Null
    Write-Host "   firewall: TCP $Port allowed on the private profile"
}

# 6. scheduled task at logon
$runner = Join-Path $PSScriptRoot "run-relay.cmd"
$action = New-ScheduledTaskAction -Execute $runner -WorkingDirectory $Home_
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName "LutronRelay" -Action $action -Trigger $trigger -Settings $settings -Description "Lutron relay (savantsniffer)" -Force | Out-Null
Write-Host "   scheduled task 'LutronRelay' registered (runs at logon, restarts if it stops)"

$tok = (Get-Content $Cfg | Where-Object { $_ -match '^token:' }) -replace '^token:\s*', ''
Write-Host ""
Write-Host "Done. Next:" -ForegroundColor Green
Write-Host "  1. copy caseta.key, caseta.crt, caseta-bridge.crt from the Mac into  $Certs"
Write-Host "  2. Start-ScheduledTask -TaskName LutronRelay      (or sign out and back in)"
Write-Host "  3. open http://localhost:$Port  and enter the token:  $tok"
Write-Host "     from other devices: http://<this PC's IP>:$Port"
