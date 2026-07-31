$log = "$PSScriptRoot\ntp-advanced.log"
$out = New-Object System.Collections.Generic.List[string]
$out.Add("=== ntp-advanced run $(Get-Date -Format o) ===")

Set-Service w32time -StartupType Automatic
w32tm /config /manualpeerlist:"levylab-ntp.phyast.pitt.edu,0x8" /syncfromflags:manual /update | Out-Null

$cfg = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
Set-ItemProperty $cfg MaxAllowedPhaseOffset 1
Set-ItemProperty $cfg UpdateInterval 100
Set-ItemProperty $cfg PhaseCorrectRate 7
Set-ItemProperty $cfg FrequencyCorrectRate 2
Set-ItemProperty $cfg MinPollInterval 4
Set-ItemProperty $cfg MaxPollInterval 6
Set-ItemProperty $cfg MaxPosPhaseCorrection 3600
Set-ItemProperty $cfg MaxNegPhaseCorrection 3600
$out.Add("registry values set")

Stop-Service w32time -Force

# one-time hard step: measure offset against the server, apply it directly
$chart = w32tm /stripchart /computer:10.226.177.233 /samples:1 /dataonly | Out-String
$out.Add("stripchart: $chart")
if ($chart -match ',\s*([+-]?\d+\.\d+)s') {
    $offset = [double]$Matches[1]
    Set-Date -Adjust ([TimeSpan]::FromSeconds($offset)) | Out-Null
    $out.Add("stepped clock by $offset s")
} else {
    $out.Add("STEP SKIPPED: could not parse offset")
}

Start-Service w32time
Start-Sleep -Seconds 3
$out.Add((w32tm /resync | Out-String))
Start-Sleep -Seconds 2
$out.Add("---- status ----")
$out.Add((w32tm /query /status | Out-String))
$out.Add("---- config ----")
$out.Add((w32tm /query /configuration | Out-String))
$out.Add("DONE")
$out | Set-Content $log -Encoding utf8
