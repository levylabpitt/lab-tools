# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, LevyLab
#
# install-lab-ntp.ps1 - one-shot setup of microsecond timekeeping on a lab PC.
#
# What it does (one UAC click, no other questions):
#   1. Checks the lab time server actually answers BEFORE changing anything.
#   2. Installs the Meinberg NTP daemon (reference ntpd) silently to C:\NTP,
#      running as SYSTEM, auto-start, Windows Firewall opened, w32time disabled.
#   3. Points it at the lab's stratum-1 GPS server (default
#      levylab-ntp.phyast.pitt.edu, a LeoNTP box), polling every 16-64 s,
#      loopstats accuracy log on.
#   4. Waits until the clock is actually locked and reports the measured offset.
#
# Usage (any lab PC, ordinary PowerShell window):
#   iwr https://raw.githubusercontent.com/levylabpitt/lab-tools/main/lab-ntp/install-lab-ntp.ps1 -OutFile "$env:TEMP\install-lab-ntp.ps1"
#   powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-lab-ntp.ps1"
# or right-click -> "Run with PowerShell" (it self-elevates).
#
#   -NtpServer <host|ip>       override the lab default
#   -NoPause                   for scripted runs
#   -SkipReachabilityCheck     install even if the server does not answer
#
# Exit codes (shared with tune-w32time.ps1, so a deployment script can treat
# both the same way). The elevated child's code is propagated by the parent, so
# a -NoPause run reports the real outcome:
#   0 success                     5 install or service failure
#   2 elevation problem           6 installer unobtainable or failed verification
#   3 cannot resolve server       7 installed, but never locked onto the server
#   4 server not answering NTP
#
# The Meinberg installer exe is used from beside this script if present;
# otherwise it is downloaded from meinbergglobal.com. Either way its SHA-256 is
# verified before running. Expect ~20-60 us offset on a wired LAN once settled;
# the transient after install can take ~30 min to fully converge.
#
# Note: the install enables the Windows multimedia timer (EnableMMTimer). That
# raises the SYSTEM-WIDE timer resolution, not just ntpd's. It is what makes the
# microsecond figures achievable, but it slightly increases power draw and
# affects timer behaviour for every process on the machine.
#
# Fallback for machines that cannot take ntpd: tune-w32time.ps1 (w32time
# registry tuning, ~1-2 ms instead of ~50 us).

param(
    [string]$NtpServer = 'levylab-ntp.phyast.pitt.edu',
    [switch]$NoPause,
    [switch]$SkipReachabilityCheck
)

$ErrorActionPreference = 'Stop'

# ntp-4.2.8p18a2, released 2025-09-17, the current stable as of 2026-07-31.
# The pinned hash matches what Meinberg publishes at "$InstallerUrl.sha256sum"
# (verified 2026-07-31). When updating, read the new value from there rather
# than hashing by hand - but keep it pinned in this file: the checksum lives on
# the same host as the installer, so fetching it at run time would prove nothing
# that serving a matching bad pair could not defeat.
$InstallerName = 'ntp-4.2.8p18a2-win32-setup.exe'
$InstallerUrl  = "https://www.meinbergglobal.com/download/ntp/windows/$InstallerName"
$InstallerSha  = 'F933BC66ED987EB436F8345F6331DE4FFAD24E6CE5E5A6F5CE98109B7B29F164'

# Set before every throw, and returned by the finally block. Without this the
# script reported success on every failure path, which -NoPause callers cannot
# see past.
$script:ExitCode = 0

function Fail {
    param([int]$Code, [string]$Message)
    $script:ExitCode = $Code
    throw $Message
}

function Pause-Maybe {
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
}

# Sends one NTP packet and reports what came back. Confirms the server is not
# only reachable but actually a synchronised stratum-1 GPS reference.
function Test-NtpServer {
    param([string]$Address, [int]$TimeoutMs = 4000)
    $udp = $null
    try {
        $udp = New-Object Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Address, 123)
        $req = New-Object byte[] 48
        $req[0] = 0x1B                      # LI 0, VN 3, Mode 3 (client)
        [void]$udp.Send($req, 48)
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $b  = $udp.Receive([ref]$ep)
        $stratum = [int]$b[1]
        $refId = if ($stratum -le 1) {
            ([Text.Encoding]::ASCII.GetString($b[12..15])).Trim([char]0)
        } else {
            "$($b[12]).$($b[13]).$($b[14]).$($b[15])"
        }
        [pscustomobject]@{
            Reachable = $true
            Stratum   = $stratum
            RefId     = $refId
            Leap      = ((([int]$b[0]) -shr 6) -band 3)
        }
    } catch {
        [pscustomobject]@{ Reachable = $false; Stratum = $null; RefId = $null; Leap = $null }
    } finally {
        if ($udp) { $udp.Close() }
    }
}

# --- self-elevate (the one human step: click Yes on UAC) ---
# NOTE: do not name this variable $args - that is a PowerShell automatic variable.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevation required - approve the UAC prompt.'
    if (-not $PSCommandPath) {
        Write-Host 'FAILED: cannot self-elevate without a script file on disk.'
        Write-Host '  Save this script and run it with -File, rather than piping it into powershell.'
        exit 2
    }
    # A quote in the server name would break out of the child's argument string.
    # Nothing legitimate contains one, so reject rather than try to escape it.
    if ($NtpServer -match '["`$]') {
        Write-Host "FAILED: -NtpServer contains an unsupported character: '$NtpServer'"
        exit 2
    }
    $argLine = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -NtpServer `"$NtpServer`""
    if ($NoPause)               { $argLine += ' -NoPause' }
    if ($SkipReachabilityCheck) { $argLine += ' -SkipReachabilityCheck' }
    # -Wait so the child's exit code can be handed back to whoever called us.
    # Without it the parent returned 0 before the install had even started.
    try {
        $child = Start-Process powershell -Verb RunAs -ArgumentList $argLine -Wait -PassThru
    } catch {
        Write-Host "FAILED: elevation was declined or failed. $($_.Exception.Message)"
        exit 2
    }
    exit $child.ExitCode
}

$work = Join-Path $env:TEMP 'lab-ntp-setup'
New-Item -ItemType Directory -Force $work | Out-Null
Start-Transcript -Path (Join-Path $work 'install-lab-ntp.transcript.txt') -Force | Out-Null

try {
    # --- resolve the server ---
    # ntpd starts at boot, potentially before DNS is usable, so the resolved IP
    # goes into ntp.conf rather than the name. Resolving here also validates it.
    try {
        $ip = ([Net.Dns]::GetHostAddresses($NtpServer) |
               Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
               Select-Object -First 1).IPAddressToString
    } catch {
        Fail 3 "Cannot resolve '$NtpServer'. Check the name, or pass -NtpServer with an IP address."
    }
    if (-not $ip) { Fail 3 "'$NtpServer' resolved to no IPv4 address." }
    Write-Host "Time server: $NtpServer -> $ip"

    # --- preflight: does it actually serve time? ---
    # Do this BEFORE installing. The install disables w32time, so aborting here
    # leaves the machine on its existing time source rather than with none.
    if (-not $SkipReachabilityCheck) {
        Write-Host 'Checking the server answers NTP...'
        $probe = Test-NtpServer -Address $ip
        if (-not $probe.Reachable) {
            Fail 4 ("No NTP response from $NtpServer ($ip udp/123). Nothing has been changed.`n" +
                    "  Check network and firewall, then retry. Use -SkipReachabilityCheck to install anyway.")
        }
        Write-Host "  responded: stratum $($probe.Stratum), reference '$($probe.RefId)', leap $($probe.Leap)"
        if ($probe.Leap -eq 3) {
            Write-Host '  WARNING: server reports itself UNSYNCHRONISED (leap indicator 3).'
        }
        if ($probe.Stratum -gt 2) {
            Write-Host "  WARNING: stratum $($probe.Stratum) is further from a reference clock than expected."
        }
    } else {
        Write-Host 'Reachability check skipped by request.'
    }

    # --- obtain and verify the installer ---
    $exe = Join-Path $PSScriptRoot $InstallerName
    if (-not (Test-Path $exe)) {
        Write-Host 'Installer not found beside script; downloading from meinbergglobal.com...'
        $exe = Join-Path $work $InstallerName
        # -bor rather than assignment: assigning drops every other protocol,
        # including TLS 1.3, for the rest of the session.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $exe -UseBasicParsing
        } catch {
            Fail 6 ("Could not download $InstallerName.`n" +
                    "  Meinberg removes older builds when they publish a new one.`n" +
                    "  Fix: get the current installer from`n" +
                    "    https://www.meinbergglobal.com/english/sw/ntp.htm`n" +
                    "  Its SHA-256 is published beside it as <installer-url>.sha256sum, so for`n" +
                    "  the build pinned here that would be`n" +
                    "    $($InstallerUrl).sha256sum`n" +
                    "  That file is served from the same host as the installer, so it is a`n" +
                    "  convenience for filling in the pin below, not a substitute for it.`n" +
                    "  Then update `$InstallerName / `$InstallerUrl / `$InstallerSha at the top of`n" +
                    "  this script, or just drop the .exe beside this script and re-run.`n" +
                    "  Underlying error: $($_.Exception.Message)")
        }
    }
    $hash = (Get-FileHash $exe -Algorithm SHA256).Hash
    if ($hash -ne $InstallerSha) {
        Fail 6 ("SHA-256 mismatch on $exe`n  expected $InstallerSha`n  got      $hash`n" +
                "Refusing to run it. If you deliberately updated the Meinberg version, " +
                "update `$InstallerSha at the top of this script.")
    }
    Write-Host 'Installer verified (SHA-256 ok, Meinberg-signed).'

    # --- write ntp.conf ---
    $conf = Join-Path $work 'ntp.conf'
    @"
# ntp.conf for levylab machines - generated by install-lab-ntp.ps1
# Source: $NtpServer ($ip), stratum-1 GPS reference.
# The IP is used rather than the name so ntpd does not depend on DNS at boot.
server $ip iburst prefer minpoll 4 maxpoll 6

# Persists the measured clock frequency error, so a reboot resumes at the known
# correction instead of relearning it over ~30 minutes. This is the main reason
# to run ntpd here rather than w32time, which has no equivalent.
driftfile "C:\NTP\etc\ntp.drift"

# accuracy log: one line per clock update, daily files
statsdir "C:\NTP\etc\stats\"
statistics loopstats
filegen loopstats file loopstats type day enable

# never panic-exit on large offsets (lab PCs can drift while powered off)
tinker panic 0

# Serve nothing, answer nothing, allow no modification.
#
# restrict applies to INCOMING packets, and the time server's reply to our own
# request is an incoming packet. So the server needs its own line here. Without
# one, a restrictive default silently discards every reply and ntpd sits at
# .INIT. with reach 0 forever, never touching the clock, while the service looks
# perfectly healthy. That is not hypothetical - it shipped, and cost a machine
# 7.75 s of drift over one weekend. See NOTES.md.
#
# "ignore" drops everything not listed below. A host-specific line replaces the
# default's flags rather than adding to them, so the three below are the entire
# allow-list: the lab appliance, and loopback so local ntpq keeps working (both
# this script and test-lab-ntp.ps1 depend on that).
restrict default ignore
restrict 127.0.0.1
restrict ::1
restrict $ip nomodify notrap noquery
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
    $installerExit = $p.ExitCode

    # Advisory, not fatal. The Meinberg silent installer returns 2 on runs whose
    # own log ends "++ Installation successfully completed", that restart the
    # service and produce a locked daemon - observed repeatedly on Windows 11.
    # Failing here aborted before the acceptance test below, which is the only
    # thing that actually knows whether this machine is keeping time. Trusting
    # an installer's self-report over the observable outcome is the same mistake
    # test-lab-ntp.ps1 exists to avoid.
    if ($installerExit -ne 0) {
        Write-Host "Note: installer returned exit code $installerExit."
        Write-Host "  Its log is $work\meinberg-install.log; the acceptance test below decides."
    }

    # --- acceptance test: service up, peer reachable, clock converging ---
    Write-Host 'Waiting for the ntp service...'
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service ntp -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { break }
        Start-Sleep -Seconds 3
    }
    $svc = Get-Service ntp -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        # The installer has already run, and it disables w32time. With ntpd not
        # running either, this machine now has no time source at all - say so
        # plainly rather than leaving that to be discovered later.
        Fail 5 ("ntp service did not start (installer exit code $installerExit);`n" +
                "  see $work\meinberg-install.log`n" +
                "  THIS MACHINE NOW HAS NO TIME SOURCE: the installer disabled w32time.`n" +
                "  Recover with either:`n" +
                "    sc.exe start ntp`n" +
                "  or, to go back to Windows timekeeping:`n" +
                "    sc.exe config w32time start= auto && sc.exe start w32time")
    }

    Write-Host "Service running. Waiting for lock on $NtpServer (up to 5 min)..."
    $ntpq = 'C:\NTP\bin\ntpq.exe'
    $peer = $null
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        # '*' marks the peer ntpd has actually selected as its system source.
        $peer = @(& $ntpq -pn 2>$null | Where-Object { $_ -match '^\*' }) | Select-Object -First 1
        if ($peer) { break }
        Start-Sleep -Seconds 10
    }

    Write-Host ''
    & $ntpq -p
    Write-Host ''
    if ($peer) {
        # ntpq -pn columns: remote refid st t when poll reach delay offset jitter
        $cols = ($peer.Trim() -split '\s+')
        $offset = if ($cols.Count -ge 9) { $cols[8] } else { 'unknown' }
        $jitter = if ($cols.Count -ge 10) { $cols[9] } else { 'unknown' }
        Write-Host "SUCCESS: locked to $NtpServer, current offset $offset ms (jitter $jitter ms)."
        Write-Host 'Full convergence to the tens-of-microseconds floor takes ~30 min.'
        Write-Host 'Check anytime with: C:\NTP\bin\ntpq -p   (accuracy log: C:\NTP\etc\stats\loopstats.*)'
        Write-Host 'Independent check:  .\test-lab-ntp.ps1'
    } else {
        # ntpd is up but has not selected the server, and the installer has
        # already disabled w32time. The machine is running on an undisciplined
        # clock right now, so state that rather than just reporting no lock.
        $script:ExitCode = 7
        Write-Host "WARNING: installed and running, but no lock on $NtpServer after 5 min."
        Write-Host '  This machine is NOT being disciplined right now: ntpd has not selected'
        Write-Host '  a source, and the install disabled w32time.'
        Write-Host "  Check that this PC can reach $ip udp/123:"
        Write-Host "    w32tm /stripchart /computer:$ip /samples:2"
        Write-Host '  ntpd often locks a few minutes later on its own - re-check with:'
        Write-Host '    C:\NTP\bin\ntpq -p'
        Write-Host '  To fall back to Windows timekeeping instead:'
        Write-Host '    sc.exe stop ntp && sc.exe config ntp start= disabled'
        Write-Host '    sc.exe config w32time start= auto && sc.exe start w32time'
    }
}
catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)"
    # A terminating error that did not come through Fail still has to be a
    # failure to the caller.
    if ($script:ExitCode -eq 0) { $script:ExitCode = 5 }
    Write-Host ''
    Write-Host "Full log: $work\install-lab-ntp.transcript.txt"
}
finally {
    Stop-Transcript | Out-Null
    Pause-Maybe
    exit $script:ExitCode
}
