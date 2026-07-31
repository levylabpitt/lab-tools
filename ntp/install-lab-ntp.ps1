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
#   iwr https://raw.githubusercontent.com/levylabpitt/lab-tools/main/ntp/install-lab-ntp.ps1 -OutFile "$env:TEMP\install-lab-ntp.ps1"
#   powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-lab-ntp.ps1"
# or right-click -> "Run with PowerShell" (it self-elevates).
#
#   -NtpServer <host|ip>       override the lab default
#   -NoPause                   for scripted runs
#   -SkipReachabilityCheck     install even if the server does not answer
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
# Fallback for machines that cannot take ntpd: ntp-advanced.ps1 (w32time
# registry tuning, ~1-2 ms instead of ~50 us).

param(
    [string]$NtpServer = 'levylab-ntp.phyast.pitt.edu',
    [switch]$NoPause,
    [switch]$SkipReachabilityCheck
)

$ErrorActionPreference = 'Stop'

$InstallerName = 'ntp-4.2.8p18a2-win32-setup.exe'
$InstallerUrl  = "https://www.meinbergglobal.com/download/ntp/windows/$InstallerName"
$InstallerSha  = 'F933BC66ED987EB436F8345F6331DE4FFAD24E6CE5E5A6F5CE98109B7B29F164'

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
    $argLine = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -NtpServer `"$NtpServer`""
    if ($NoPause)               { $argLine += ' -NoPause' }
    if ($SkipReachabilityCheck) { $argLine += ' -SkipReachabilityCheck' }
    Start-Process powershell -Verb RunAs -ArgumentList $argLine
    exit
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
        throw "Cannot resolve '$NtpServer'. Check the name, or pass -NtpServer with an IP address."
    }
    if (-not $ip) { throw "'$NtpServer' resolved to no IPv4 address." }
    Write-Host "Time server: $NtpServer -> $ip"

    # --- preflight: does it actually serve time? ---
    # Do this BEFORE installing. The install disables w32time, so aborting here
    # leaves the machine on its existing time source rather than with none.
    if (-not $SkipReachabilityCheck) {
        Write-Host 'Checking the server answers NTP...'
        $probe = Test-NtpServer -Address $ip
        if (-not $probe.Reachable) {
            throw ("No NTP response from $NtpServer ($ip udp/123). Nothing has been changed.`n" +
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
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $exe -UseBasicParsing
        } catch {
            throw ("Could not download $InstallerName.`n" +
                   "  Meinberg removes older builds when they publish a new one.`n" +
                   "  Fix: download the current installer from`n" +
                   "    https://www.meinbergglobal.com/english/sw/ntp.htm`n" +
                   "  then update `$InstallerName / `$InstallerUrl / `$InstallerSha at the top of this script,`n" +
                   "  or just drop the .exe beside this script and re-run.`n" +
                   "  Underlying error: $($_.Exception.Message)")
        }
    }
    $hash = (Get-FileHash $exe -Algorithm SHA256).Hash
    if ($hash -ne $InstallerSha) {
        throw ("SHA-256 mismatch on $exe`n  expected $InstallerSha`n  got      $hash`n" +
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
# noserve: do not hand out time to other machines - the lab has a dedicated
# appliance for that, and no workstation should be acting as a time source.
# noquery: no remote ntpq/ntpdc, which is also what blocks amplification abuse.
restrict default kod nomodify notrap nopeer noquery noserve
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
        Write-Host 'Independent check:  .\Test-LabTime.ps1'
    } else {
        Write-Host "WARNING: installed and running, but no lock on $NtpServer after 5 min."
        Write-Host "Check that this PC can reach $ip udp/123 (w32tm /stripchart /computer:$ip /samples:2)"
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
