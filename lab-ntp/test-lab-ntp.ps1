# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, LevyLab

<#
.SYNOPSIS
    Independent health check for lab timekeeping. Works whether the machine runs
    the Meinberg NTP daemon or Windows' w32time.

.DESCRIPTION
    Measures the clock against the lab time server directly, using its own NTP
    queries rather than asking the local daemon how it thinks it is doing. That
    matters: "ntpq -p" reports ntpd's estimate of its own error, which is not an
    independent check.

    Emits one object per machine so results can be collected across the lab.
    Read-only, needs no elevation, and changes nothing.

    Two numbers carry uncertainty estimates, and both matter:

      Residual Drift (ppm)  - how fast the clock is still gaining or losing.
                              Near zero means the frequency error is corrected.
      Offset (ms)           - how far from the reference right now.

    Network jitter can swamp both over a short run, so each is reported with its
    own uncertainty and neither is failed on a difference the measurement cannot
    actually resolve.

    Result is PASS or FAIL, and is decided by Issues alone. Anything the run
    could not determine goes to Notes instead, which does not affect the
    verdict: a measurement that failed to resolve drift is not evidence of a bad
    clock, and grading it as one would be the same mistake the uncertainty
    margins exist to avoid.

.PARAMETER NtpServer
    Reference to measure against. Defaults to the lab GPS appliance.

    Deliberately a fixed reference rather than "whatever this machine syncs to".
    A machine left on time.windows.com would sync happily and report a small
    offset, hiding that it is not using the lab source at all.

.PARAMETER Samples
    Number of measurements. Default 30, which at the default 8 s period takes 4
    minutes and measures offset well. Drift needs a longer window: 60 samples
    takes 8 minutes and resolves drift to about 1 ppm. Watch 'Drift Quality' to
    see whether the run resolved it - if it did not, that appears in Notes and
    does not fail the machine.

.PARAMETER PeriodSeconds
    Seconds between samples. Default 8. Polling faster than this can trip an NTP
    server's rate limiting, which shows up as dropped samples or a stalled run.

    For drift precision, a longer window beats more samples: 60 samples at 8 s
    resolves slope about as well as 150 samples at 2 s, using 60% fewer packets.

.PARAMETER ToleranceMs
    Offset threshold for PASS. Default 1 ms.

.PARAMETER NtpqPath
    Where to find ntpq.exe, for reading ntpd's own view of its peer. Defaults to
    the location install-lab-ntp.ps1 uses. If it is missing, the ntpd peer
    fields are left empty and the run says so in Notes rather than concluding
    the daemon is unlocked.

.EXAMPLE
    .\test-lab-ntp.ps1

.EXAMPLE
    .\test-lab-ntp.ps1 -Samples 60 -Verbose

.EXAMPLE
    # Lab sweep, assuming WinRM is enabled on the targets
    $r = Invoke-Command -ComputerName (Get-Content .\computers.txt) -FilePath .\test-lab-ntp.ps1
    $r | Sort-Object 'Offset (ms)' | Format-Table Computer,Daemon,'Offset (ms)','Residual Drift (ppm)',Result
#>
[CmdletBinding()]
param(
    [string]$NtpServer = 'levylab-ntp.phyast.pitt.edu',
    [ValidateRange(6, 450)][int]$Samples = 30,
    [ValidateRange(1, 60)][int]$PeriodSeconds = 8,
    [double]$ToleranceMs = 1.0,
    [string]$NtpqPath = 'C:\NTP\bin\ntpq.exe',
    [switch]$ProgressBar,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0

# Issues decide PASS/FAIL. Notes record what the run could not determine, and
# deliberately do not.
$issues = @()
$notes  = @()

# ---------------------------------------------------------- which daemon? ----

$ntpq    = $NtpqPath
$ntpdSvc = Get-Service ntp     -ErrorAction SilentlyContinue
$w32Svc  = Get-Service W32Time -ErrorAction SilentlyContinue

$daemon = 'none'
if     ($ntpdSvc -and $ntpdSvc.Status -eq 'Running') { $daemon = 'ntpd' }
elseif ($w32Svc  -and $w32Svc.Status  -eq 'Running') { $daemon = 'w32time' }

$peerLine = $null; $peerOffsetMs = $null; $peerJitterMs = $null
$reach = $null; $stratum = $null; $source = $null; $startMode = $null
$disciplineOn = $null; $granularityPpm = $null

$ntpqAvailable = $false

if ($daemon -eq 'ntpd') {
    $startMode = (Get-CimInstance Win32_Service -Filter "Name='ntp'" -ErrorAction SilentlyContinue).StartMode
    $ntpqAvailable = Test-Path $ntpq
    if ($ntpqAvailable) {
        # '*' marks the peer ntpd has selected as its system source.
        $peerLine = @(& $ntpq -pn 2>$null | Where-Object { $_ -match '^\*' }) | Select-Object -First 1
        if ($peerLine) {
            $cols = ($peerLine.Trim() -split '\s+')
            $source = $cols[0].TrimStart('*')
            if ($cols.Count -ge 3)  { $stratum      = $cols[2] }
            if ($cols.Count -ge 7)  { $reach        = $cols[6] }
            if ($cols.Count -ge 9)  { $peerOffsetMs = [double]$cols[8] }
            if ($cols.Count -ge 10) { $peerJitterMs = [double]$cols[9] }
        }
    }
    else {
        # ntpd is running but its query tool is somewhere else. That says
        # nothing about whether the clock is locked, so it must not be graded
        # as if it did - the direct measurement below still stands on its own.
        $notes += 'NtpdStatusUnavailable'
    }
}
elseif ($daemon -eq 'w32time') {
    $svcCim    = Get-CimInstance Win32_Service -Filter "Name='W32Time'" -ErrorAction SilentlyContinue
    $startMode = if ($svcCim) { $svcCim.StartMode } else { $null }
    $status    = & w32tm.exe /query /status 2>&1 | Out-String
    $stratum   = ([regex]::Match($status, 'Stratum:\s*(\d+)')).Groups[1].Value
    $source    = ([regex]::Match($status, 'Source:\s*(.+)')).Groups[1].Value.Trim()

    # 'Disabled = False' means the kernel is actively slewing the clock rate.
    if (-not ('LabTime.Clock' -as [type])) {
        Add-Type -Namespace LabTime -Name Clock -MemberDefinition @'
[DllImport("api-ms-win-core-sysinfo-l1-2-4.dll", SetLastError=true)]
public static extern bool GetSystemTimeAdjustmentPrecise(out ulong adj, out ulong incr, out bool disabled);
'@ -ErrorAction SilentlyContinue
    }
    $adj = [uint64]0; $inc = [uint64]0; $dis = $false
    try {
        if ([LabTime.Clock]::GetSystemTimeAdjustmentPrecise([ref]$adj, [ref]$inc, [ref]$dis)) {
            $disciplineOn   = (-not $dis)
            $granularityPpm = if ($inc -gt 0) { [math]::Round(1e6 / $inc, 4) } else { $null }
        }
    } catch { }
}

# Is the daemon actually using the reference we are measuring against?
$sourceMatches = $null
if ($source) {
    $aliases = @($NtpServer)
    try { $aliases += ([Net.Dns]::GetHostAddresses($NtpServer) | ForEach-Object { $_.IPAddressToString }) } catch { }
    try { $aliases += ([Net.Dns]::GetHostEntry($NtpServer)).HostName } catch { }
    $sourceMatches = $false
    foreach ($a in $aliases) { if ($a -and $source -like "*$a*") { $sourceMatches = $true; break } }
}

# ------------------------------------------------------------- measure ----

$activity   = "Measuring clock against $NtpServer"
$collected  = New-Object System.Collections.Generic.List[string]
$seen       = 0
$lastOffset = $null

# ~10 permanent lines per run, but never more than ~15 s of silence.
$tick = [math]::Max(1, [math]::Min([int]($Samples / 10), [int](15 / $PeriodSeconds)))

# The spinner rewrites its line with a carriage return, which only overwrites in
# place on a real console. [Console]::IsOutputRedirected is the reliable test -
# RawUI.WindowSize and SupportsVirtualTerminal both report healthy values even
# when output is being captured.
$canAnimate = $false
if (-not $Quiet -and -not $ProgressBar) {
    try { $canAnimate = (-not [Console]::IsOutputRedirected) } catch { $canAnimate = $false }
}
$spinner = @('-', '\', '|', '/')
$spinIdx = 0
$transientWidth = 72

function Clear-Transient {
    if ($canAnimate) { Write-Host -NoNewline ("`r" + (' ' * $transientWidth) + "`r") }
}

if (-not $Quiet) {
    Write-Host $activity
    Write-Host ("  {0} samples every {1}s, roughly {2:N1} min  (daemon: {3})" -f `
                $Samples, $PeriodSeconds, ($Samples * $PeriodSeconds / 60.0), $daemon)
}

# Run w32tm as a process, not through the call operator: the pipeline only wakes
# when a line arrives, leaving no opportunity to animate or to notice a stall.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = 'w32tm.exe'
$psi.Arguments              = "/stripchart /computer:$NtpServer /samples:$Samples /period:$PeriodSeconds /dataonly"
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true

$proc     = [System.Diagnostics.Process]::Start($psi)
$errTask  = $proc.StandardError.ReadToEndAsync()   # started early to avoid a full-buffer deadlock
$reader   = $proc.StandardOutput
$lineTask = $reader.ReadLineAsync()

# Bail-out guards. w32tm can stall indefinitely when a server stops answering,
# and an unbounded read leaves the whole script hung with no output.
$stalled         = $null
$lastLineAt      = Get-Date
$stallLimit      = [math]::Max(45, $PeriodSeconds * 6)
$overallDeadline = (Get-Date).AddSeconds(($Samples * $PeriodSeconds) + 120)

while ($true) {
    if ($lineTask.Wait(120)) {
        $line = $lineTask.Result
        if ($null -eq $line) { break }
        $collected.Add($line)
        $lastLineAt = Get-Date

        if ($line -match '^(\d{2}):(\d{2}):(\d{2}),\s*([+-]\d+\.\d+)s') {
            $seen++
            $lastOffset = [double]$Matches[4]
            $remaining  = [math]::Max(0, ($Samples - $seen) * $PeriodSeconds)

            if ($ProgressBar) {
                Write-Progress -Activity $activity `
                    -Status ("sample {0} of {1}  |  offset {2:N4} s" -f $seen, $Samples, $lastOffset) `
                    -PercentComplete ([math]::Min(100, [int](100 * $seen / $Samples))) `
                    -SecondsRemaining $remaining
            }
            elseif (-not $Quiet -and ($seen -eq 1 -or $seen % $tick -eq 0 -or $seen -eq $Samples)) {
                Clear-Transient
                Write-Host ("  {0,4}/{1,-4} offset {2,10:N4} s   ~{3}s left" -f `
                            $seen, $Samples, $lastOffset, $remaining)
            }
        }
        $lineTask = $reader.ReadLineAsync()
    }
    else {
        $idleSec = ((Get-Date) - $lastLineAt).TotalSeconds
        if ($idleSec -gt $stallLimit) { $stalled = "no data for $([int]$idleSec)s"; break }
        if ((Get-Date) -gt $overallDeadline) { $stalled = 'overall deadline exceeded'; break }

        if ($canAnimate) {
            $spinIdx++
            $waitRemain = [math]::Max(0, ($Samples - $seen) * $PeriodSeconds)
            Write-Host -NoNewline ("`r   {0}  sample {1} of {2}   ~{3}s left   " -f `
                        $spinner[$spinIdx % $spinner.Count],
                        [math]::Min($seen + 1, $Samples), $Samples, $waitRemain)
        }
    }
}

Clear-Transient

# Every wait below is bounded. A stalled w32tm must never hang the script.
if (-not $proc.HasExited) {
    if (-not $proc.WaitForExit(5000)) {
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit(5000) } catch { }
    }
}
$errText = $null
try { if ($errTask.Wait(3000)) { $errText = $errTask.Result } } catch { }
if ($errText -and $errText.Trim()) { $collected.Add($errText.Trim()) }

if ($stalled) {
    # Also recorded on the object: in a lab sweep the warning stream is easy to
    # lose, and a short run is the usual reason drift did not resolve.
    $notes += 'MeasurementIncomplete'
    Write-Warning ("Measurement stopped early ($stalled). Using the $seen samples collected. " +
                   "If this repeats, the server may be rate-limiting - try a larger -PeriodSeconds.")
}
if ($ProgressBar) { Write-Progress -Activity $activity -Completed }
if (-not $Quiet)  { Write-Host '  done, analysing...' }

# ------------------------------------------------------------ analyse ----

$raw = ($collected -join [Environment]::NewLine)
$sampleMatches = [regex]::Matches($raw, '(?m)^(\d{2}):(\d{2}):(\d{2}),\s*([+-]\d+\.\d+)s')

$times = @(); $offs = @()
foreach ($m in $sampleMatches) {
    $times += ([int]$m.Groups[1].Value * 3600 + [int]$m.Groups[2].Value * 60 + [int]$m.Groups[3].Value)
    $offs  += [double]$m.Groups[4].Value
}

$offsetMs = $null; $offsetUncMs = $null; $spreadMs = $null
if ($offs.Count -gt 0) {
    $meanOff  = ($offs | Measure-Object -Average).Average
    $offsetMs = [math]::Round($meanOff * 1000, 4)
    $spreadMs = [math]::Round(((($offs | Measure-Object -Maximum).Maximum - ($offs | Measure-Object -Minimum).Minimum)) * 1000, 4)
    if ($offs.Count -ge 2) {
        # Standard error of the mean. Without this the check fails a clock on a
        # fraction of a millisecond while the measurement noise is several ms.
        $ss = 0.0
        foreach ($o in $offs) { $ss += ($o - $meanOff) * ($o - $meanOff) }
        $sd = [math]::Sqrt($ss / ($offs.Count - 1))
        $offsetUncMs = [math]::Round(($sd / [math]::Sqrt($offs.Count)) * 1000, 4)
    }
}

$driftPpm = $null; $driftUncPpm = $null; $driftQuality = 'Insufficient'; $windowSec = $null
if ($offs.Count -ge 6) {
    $n = $offs.Count
    $t0 = $times[0]; $x = @(); $addDay = 0
    for ($k = 0; $k -lt $n; $k++) {
        if ($k -gt 0 -and $times[$k] -lt $times[$k - 1]) { $addDay += 86400 }   # midnight rollover
        $x += ($times[$k] + $addDay - $t0)
    }
    $windowSec = $x[$n - 1]
    $mx = ($x | Measure-Object -Average).Average
    $my = ($offs | Measure-Object -Average).Average
    $num = 0.0; $den = 0.0
    for ($k = 0; $k -lt $n; $k++) {
        $num += ($x[$k] - $mx) * ($offs[$k] - $my)
        $den += ($x[$k] - $mx) * ($x[$k] - $mx)
    }
    if ($den -gt 0) {
        $slope = $num / $den
        $driftPpm = [math]::Round($slope * 1e6, 3)
        $b0 = $my - $slope * $mx
        $sse = 0.0
        for ($k = 0; $k -lt $n; $k++) { $r = $offs[$k] - ($b0 + $slope * $x[$k]); $sse += $r * $r }
        $s  = [math]::Sqrt($sse / [math]::Max(1, $n - 2))
        $driftUncPpm = [math]::Round(($s / [math]::Sqrt($den)) * 1e6, 3)
        # Judged against the 5 ppm pass threshold, not against the slope itself -
        # a well-disciplined clock legitimately has a slope near zero.
        if     ($driftUncPpm -le 2) { $driftQuality = 'Good' }
        elseif ($driftUncPpm -le 5) { $driftQuality = 'Marginal' }
        else                        { $driftQuality = 'Poor' }
    }
}

# -------------------------------------------------------------- grade ----

if ($daemon -eq 'none') { $issues += 'NoTimeDaemon' }
if ($daemon -eq 'ntpd' -and $ntpqAvailable -and -not $peerLine) { $issues += 'NtpdNotLocked' }
if ($daemon -eq 'w32time') {
    if ($startMode -ne 'Auto')    { $issues += 'NotAutomatic' }
    if ($disciplineOn -eq $false) { $issues += 'ClockFreeRunning' }
}
if ($sourceMatches -eq $false) { $issues += 'WrongSource' }

if ($null -eq $offsetMs) {
    $issues += 'ReferenceUnreachable'
} else {
    # Only fail when the offset exceeds tolerance by more than the measurement
    # can explain. 2 sigma keeps a noisy network from failing a healthy clock.
    $margin = if ($offsetUncMs) { 2 * $offsetUncMs } else { 0 }
    if (([math]::Abs($offsetMs) - $margin) -gt $ToleranceMs) { $issues += 'OffsetOutOfTolerance' }
}

# Always applied. The 2-sigma margin already absorbs an imprecise run: a noisy
# -8 +/- 4.9 ppm cannot clear it, because that range includes zero. Gating this
# on Drift Quality as well conflated how *precisely* the slope was measured with
# how *large* it is, and swallowed a real 51.34 +/- 5.69 ppm - nine sigma from
# zero, on a machine that had never once been disciplined - purely because the
# uncertainty exceeded 5 ppm.
if ($null -ne $driftPpm) {
    $driftMargin = if ($driftUncPpm) { 2 * $driftUncPpm } else { 0 }
    if (([math]::Abs($driftPpm) - $driftMargin) -gt 5) { $issues += 'HighResidualDrift' }
}

# Informational: how well this run resolved the slope, never a verdict on the
# clock. Failing on it would condemn a healthy machine for a short or noisy run.
if ($driftQuality -ne 'Good' -and $driftQuality -ne 'Marginal') {
    $notes += 'DriftNotResolvable'
}
if ($null -ne $stratum -and "$stratum" -ne '' -and [int]$stratum -gt 5) { $issues += 'StratumTooHigh' }

[pscustomobject]@{
    Computer                   = $env:COMPUTERNAME
    Timestamp                  = (Get-Date)
    Result                     = if ($issues.Count -eq 0) { 'PASS' } else { 'FAIL' }
    Issues                     = ($issues -join ', ')
    Notes                      = ($notes -join ', ')
    Daemon                     = $daemon
    'Offset (ms)'              = $offsetMs
    'Offset Uncertainty (ms)'  = $offsetUncMs
    'Residual Drift (ppm)'     = $driftPpm
    'Drift Uncertainty (ppm)'  = $driftUncPpm
    'Drift Quality'            = $driftQuality
    Source                     = $source
    'Source Matches Ref'       = $sourceMatches
    Stratum                    = $stratum
    'Start Mode'               = $startMode
    'Discipline Active'        = $disciplineOn
    'Peer Offset (ms)'         = $peerOffsetMs
    'Peer Jitter (ms)'         = $peerJitterMs
    Reach                      = $reach
    'Reference Server'         = $NtpServer
    'Sample Spread (ms)'       = $spreadMs
    Samples                    = $offs.Count
    'Window (s)'               = $windowSec
    'Adjust Granularity (ppm)' = $granularityPpm
}
