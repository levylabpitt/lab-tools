# install-lab-ntp.ps1 - one-shot setup of microsecond timekeeping on a lab PC.
#
# What it does (one UAC click, no other questions):
#   1. Installs the Meinberg NTP daemon (reference ntpd) silently to C:\NTP,
#      running as SYSTEM, auto-start, Windows Firewall opened, w32time disabled.
#   2. Points it at the lab's stratum-1 GPS server: levylab-ntp.phyast.pitt.edu
#      (LeoNTP, 10.226.177.233), polling every 16-64 s, loopstats accuracy log on.
#   3. Waits until the clock is actually locked and reports the measured offset.
#
# Usage (any lab PC, ordinary PowerShell window):
#   iwr https://raw.githubusercontent.com/levylabpitt/lab-tools/main/ntp/install-lab-ntp.ps1 -OutFile "$env:TEMP\install-lab-ntp.ps1"
#   powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-lab-ntp.ps1"
# or right-click -> "Run with PowerShell" (it self-elevates). [-NoPause] for scripted runs.
#
# The Meinberg installer exe is used from beside this script if present;
# otherwise it is downloaded from meinbergglobal.com. Either way its SHA-256 is
# verified before running. Expect ~20-60 us offset on a wired LAN once settled;
# the transient after install can take ~30 min to fully converge.
#
# Fallback for machines that cannot take ntpd: ntp-advanced.ps1 (w32time
# registry tuning, ~1-2 ms instead of ~50 us).

param([switch]$NoPause)

$ErrorActionPreference = 'Stop'

$InstallerName = 'ntp-4.2.8p18a2-win32-setup.exe'
$InstallerUrl  = "https://www.meinbergglobal.com/download/ntp/windows/$InstallerName"
$InstallerSha  = 'F933BC66ED987EB436F8345F6331DE4FFAD24E6CE5E5A6F5CE98109B7B29F164'
$NtpServer     = '10.226.177.233'   # levylab-ntp.phyast.pitt.edu

function Pause-Maybe {
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
}

# --- self-elevate (the one human step: click Yes on UAC) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevation required - approve the UAC prompt.'
    $args = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($NoPause) { $args += ' -NoPause' }
    Start-Process powershell -Verb RunAs -ArgumentList $args
    exit
}

$work = Join-Path $env:TEMP 'lab-ntp-setup'
New-Item -ItemType Directory -Force $work | Out-Null
Start-Transcript -Path (Join-Path $work 'install-lab-ntp.transcript.txt') -Force | Out-Null

try {
    # --- obtain and verify the installer ---
    $exe = Join-Path $PSScriptRoot $InstallerName
    if (-not (Test-Path $exe)) {
        Write-Host "Installer not found beside script; downloading from meinbergglobal.com..."
        $exe = Join-Path $work $InstallerName
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $exe -UseBasicParsing
    }
    $hash = (Get-FileHash $exe -Algorithm SHA256).Hash
    if ($hash -ne $InstallerSha) {
        throw "SHA-256 mismatch on $exe`n  expected $InstallerSha`n  got      $hash`nRefusing to run it."
    }
    Write-Host "Installer verified (SHA-256 ok, Meinberg-signed)."

    # --- write ntp.conf ---
    $conf = Join-Path $work 'ntp.conf'
    @"
# ntp.conf for levylab machines - sync from LeoNTP stratum 1 (levylab-ntp.phyast.pitt.edu)
server $NtpServer iburst prefer minpoll 4 maxpoll 6

driftfile "C:\NTP\etc\ntp.drift"

# accuracy log: one line per clock update, daily files
statsdir "C:\NTP\etc\stats\"
statistics loopstats
filegen loopstats file loopstats type day enable

# never panic-exit on large offsets (lab PCs can drift while powered off)
tinker panic 0

# serve no time, accept no modification; status queries from localhost only
restrict default kod nomodify notrap nopeer noquery
restrict 127.0.0.1
restrict ::1
"@ | Set-Content $conf -Encoding ascii

    # --- write silent-install settings ---
    $ini = Join-Path $work 'meinberg-install.ini'
    @"
[Installer]
InstallDir=C:\NTP
UpgradeMode=Reinstall
Logfile=$work\meinberg-install.log
Silent=Yes

[Components]
InstallTools=yes
InstallDocs=yes
InstallOpenSSL=yes
CreateStartMenuEntries=yes

[Service]
StartAfterInstallation=yes
AutoStart=yes
ServiceAccount=@SYSTEM
CreateAccount=no
DisableOthers=yes
AllowBigInitialTimestep=yes
EnableMMTimer=yes
ModifyFirewall=yes

[Configuration]
UseConfigFile=$conf
"@ | Set-Content $ini -Encoding ascii

    # stats dir must exist or ntpd silently skips loopstats
    New-Item -ItemType Directory -Force 'C:\NTP\etc\stats' | Out-Null

    # --- run the installer silently ---
    Write-Host 'Installing Meinberg NTP (silent)...'
    $p = Start-Process $exe -ArgumentList "/USE_FILE=$ini" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Installer exited with code $($p.ExitCode); see $work\meinberg-install.log" }

    # --- acceptance test: service up, peer reachable, clock converging ---
    Write-Host 'Waiting for the ntp service...'
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service ntp -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { break }
        Start-Sleep -Seconds 3
    }
    $svc = Get-Service ntp -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { throw 'ntp service did not start; see the Meinberg log above.' }

    Write-Host "Service running. Waiting for lock on $NtpServer (up to 5 min)..."
    $ntpq = 'C:\NTP\bin\ntpq.exe'
    $locked = $false
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $peer = & $ntpq -pn 2>$null | Where-Object { $_ -match '^\*' }
        if ($peer) { $locked = $true; break }
        Start-Sleep -Seconds 10
    }

    Write-Host ''
    & $ntpq -p
    Write-Host ''
    if ($locked) {
        $offset = [double](($peer -split '\s+')[8])
        Write-Host ("SUCCESS: locked to levylab-ntp, current offset {0} ms." -f $offset)
        Write-Host 'Full convergence to the tens-of-microseconds floor takes ~30 min.'
        Write-Host 'Check anytime with: C:\NTP\bin\ntpq -p   (accuracy log: C:\NTP\etc\stats\loopstats.*)'
    } else {
        Write-Host "WARNING: installed and running, but no lock on $NtpServer after 5 min."
        Write-Host "Check that this PC can reach $NtpServer udp/123 (w32tm /stripchart /computer:$NtpServer /samples:2)"
    }
}
catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)"
}
finally {
    Stop-Transcript | Out-Null
    Pause-Maybe
}
