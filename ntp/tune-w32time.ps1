# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, LevyLab
#
# tune-w32time.ps1 - FALLBACK ONLY, for machines that cannot run the NTP daemon.
#
# Prefer install-lab-ntp.ps1. This script is the worse option, kept for machines
# where installing a daemon is not permitted: it tunes Windows' built-in w32time
# for the best accuracy it can reach, ~1-2 ms rather than the ~50 us that
# install-lab-ntp.ps1 achieves.
#
# The big caveat, and the reason this is the fallback: w32time has no driftfile.
# It relearns the clock's frequency error from scratch on every boot, taking
# ~30-60 min to reconverge each time. See NOTES.md.
#
# Refuses to run on a machine that already has the Meinberg ntp service, since
# that machine is already on the better path and re-enabling w32time beside ntpd
# would leave two daemons fighting over one clock. -Force performs the migration
# back to w32time properly instead, by taking ntpd out first.
#
# Usage (elevated):
#   .\tune-w32time.ps1
#   .\tune-w32time.ps1 -NtpServer 10.0.0.50 -NoStep
#   .\tune-w32time.ps1 -Force        # deliberately migrate a machine off ntpd
#
# Exit codes (shared with install-lab-ntp.ps1):
#   0 success                     4 server not answering NTP
#   2 elevation problem           5 install or configuration failure
#   3 cannot resolve server       8 refused: wrong script for this machine

param(
    [string]$NtpServer = 'levylab-ntp.phyast.pitt.edu',
    [switch]$NoStep,          # skip the one-time hard step (machines mid-acquisition)
    [switch]$Force,           # migrate a machine off ntpd back to w32time
    [string]$LogPath
)

# Not $PSScriptRoot: that drops a log into the repo working tree on every run
# from a clone. The path is echoed at the end so it is still easy to find.
if (-not $LogPath) { $LogPath = Join-Path $env:TEMP 'tune-w32time.log' }

$cfgKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
$ntpKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'

# Append as we go. Writing the log only at the end loses everything precisely
# when the script dies partway, which is when you need it most.
function Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format o)] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding utf8
}

Log "=== tune-w32time run, target $NtpServer ==="

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Log 'FAILED: must be run elevated (Run as Administrator). Nothing changed.'
    exit 2
}

# --- guard: is this even the right script for this machine? ---
# install-lab-ntp.ps1 disables w32time deliberately. Turning w32time back on
# while ntpd is still there leaves two daemons disciplining one clock, which is
# worse than either alone and awkward to diagnose: each reports itself healthy.
# The boundary between the two scripts is enforced here rather than left to the
# README, because the mistake is easy to make when working down a list of PCs.
$ntpdSvc = Get-Service ntp -ErrorAction SilentlyContinue
if ($ntpdSvc) {
    if (-not $Force) {
        Log "REFUSED: the Meinberg ntp service is present here (status $($ntpdSvc.Status))."
        Log '  That means this machine was set up with install-lab-ntp.ps1, which is the'
        Log '  better path (~50 us, and it survives reboots). Running this script would'
        Log '  re-enable w32time alongside ntpd. Nothing has been changed.'
        Log '  If ntpd is unhealthy, repair it or re-run install-lab-ntp.ps1 instead.'
        Log '  To deliberately move this machine back to w32time, re-run with -Force,'
        Log '  which stops and disables ntpd first.'
        exit 8
    }
    # -Force means "migrate properly", not "ignore the hazard": ntpd comes out
    # before w32time goes on, so the two-daemon state never exists at all.
    Log "-Force given: taking ntpd out of service first (was $($ntpdSvc.Status))."
    if ($ntpdSvc.Status -eq 'Running') { Stop-Service ntp -Force }
    Set-Service ntp -StartupType Disabled
    Log '  ntp service stopped and set to Disabled. The Meinberg installation itself is'
    Log '  left in place; remove it from Apps & Features if you want it gone entirely.'
}

try { $ip = ([Net.Dns]::GetHostAddresses($NtpServer) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString }
catch { Log "FAILED: cannot resolve '$NtpServer'. Nothing changed."; exit 3 }
Log "Resolved $NtpServer -> $ip"

# Preflight, so a bad address cannot leave the machine with no working source.
$probe = & w32tm.exe /stripchart /computer:$ip /samples:3 /period:4 /dataonly 2>&1 | Out-String
if ($probe -notmatch '(?m)^\d{2}:\d{2}:\d{2},\s*[+-]\d+\.\d+s') {
    Log "FAILED: no NTP response from $NtpServer. Nothing changed.`n$probe"
    exit 4
}
Log 'Server reachable.'

# --- registry: high-accuracy loop tuning ---
# MaxPos/MaxNegPhaseCorrection 3600 caps automatic corrections at one hour, so a
# wildly wrong estimate can never be applied silently. The hard step below is the
# deliberate escape hatch for genuinely large offsets.
$settings = @(
    @{ Key = $cfgKey; Name = 'MaxAllowedPhaseOffset';  Value = 1      }
    @{ Key = $cfgKey; Name = 'UpdateInterval';         Value = 100    }
    @{ Key = $cfgKey; Name = 'PhaseCorrectRate';       Value = 7      }
    @{ Key = $cfgKey; Name = 'FrequencyCorrectRate';   Value = 2      }
    @{ Key = $cfgKey; Name = 'MinPollInterval';        Value = 4      }
    @{ Key = $cfgKey; Name = 'MaxPollInterval';        Value = 6      }
    @{ Key = $cfgKey; Name = 'MaxPosPhaseCorrection';  Value = 3600   }
    @{ Key = $cfgKey; Name = 'MaxNegPhaseCorrection';  Value = 3600   }
    @{ Key = $cfgKey; Name = 'UtilizeSslTimeData';     Value = 0      }  # Secure Time Seeding off
    @{ Key = $ntpKey; Name = 'SpecialPollInterval';    Value = 64     }
)
foreach ($s in $settings) {
    $old = $null
    try { $old = (Get-ItemProperty -Path $s.Key -Name $s.Name -ErrorAction Stop).($s.Name) } catch { }
    New-ItemProperty -Path $s.Key -Name $s.Name -Value $s.Value -PropertyType DWord -Force | Out-Null
    if ("$old" -ne "$($s.Value)") { Log "  $($s.Name): $old -> $($s.Value)" }
}
Log 'Registry values set.'

# --- service must be RUNNING before w32tm /config ---
# "/update" signals the running service to reload. On a default machine w32time
# is trigger-start and stopped, so configuring first fails with 0x80070426 -
# and piping that to Out-Null hides it, leaving the source silently unset.
Set-Service w32time -StartupType Automatic
if ((Get-Service w32time).Status -ne 'Running') { Start-Service w32time }
Start-Sleep -Seconds 2

$out = & w32tm.exe /config "/manualpeerlist:$NtpServer,0x8" /syncfromflags:manual /update 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Log "FAILED: w32tm /config returned $LASTEXITCODE. Registry values were applied but the source is NOT set.`n$out"
    exit 5
}
Log "Peer list set to $NtpServer,0x8; service startup type Automatic."

# --- one-time hard step ---
# With corrections capped at one hour, a machine that is further off than that
# will never self-correct. Stopping the service and setting the clock directly
# is the escape hatch. Averaged over several samples - a single sample carries
# the full network jitter of that one packet.
if (-not $NoStep) {
    Stop-Service w32time -Force
    $chart = & w32tm.exe /stripchart /computer:$ip /samples:5 /period:4 /dataonly 2>&1 | Out-String
    $offsets = @([regex]::Matches($chart, '(?m)^\d{2}:\d{2}:\d{2},\s*([+-]\d+\.\d+)s') |
                 ForEach-Object { [double]$_.Groups[1].Value })
    if ($offsets.Count -gt 0) {
        $median = ($offsets | Sort-Object)[[int]([math]::Floor($offsets.Count / 2))]
        Set-Date -Adjust ([TimeSpan]::FromSeconds($median)) | Out-Null
        Log ("Stepped clock by {0:N4} s (median of {1} samples)." -f $median, $offsets.Count)
    } else {
        Log "STEP SKIPPED: could not parse any offset.`n$chart"
    }
    Start-Service w32time
    Start-Sleep -Seconds 3
} else {
    Log 'Hard step skipped by request (-NoStep).'
}

Log (& w32tm.exe /resync 2>&1 | Out-String)
Start-Sleep -Seconds 2
Log "---- status ----`n$(& w32tm.exe /query /status 2>&1 | Out-String)"
Log "---- config ----`n$(& w32tm.exe /query /configuration 2>&1 | Out-String)"
Log 'DONE. Reboot when convenient (Secure Time Seeding needs it), then verify with test-lab-ntp.ps1.'
Log "Log written to $LogPath"
