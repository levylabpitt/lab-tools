# Levy Lab Tools

Deployment scripts for Levy Lab PCs. This repo is public and contains no lab data;
it exists so any lab machine can be set up with one command, no accounts and no
shared folders.

## NTP: microsecond time sync

Every lab machine should sync its clock to the lab's stratum-1 GPS time server,
`levylab-ntp.phyast.pitt.edu` (a LeoNTP box, accurate to ~30 ns). The script below
installs the Meinberg NTP daemon (signed installer, SHA-256 pinned), disables
Windows' built-in w32time, points the daemon at the lab server, and verifies the
clock actually locks before reporting success.

It checks the time server answers **before** changing anything, so a network
problem leaves the machine on its existing source rather than with none.

On the lab PC, open PowerShell and run:

```powershell
iwr https://raw.githubusercontent.com/levylabpitt/lab-tools/main/ntp/install-lab-ntp.ps1 -OutFile "$env:TEMP\install-lab-ntp.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-lab-ntp.ps1"
```

Click **Yes** on the single UAC prompt. The script prints `SUCCESS` with the
measured clock offset once locked. Expect roughly 20-60 microseconds after ~30
minutes of settling.

Point it somewhere else with `-NtpServer <host|ip>` if you need to.

### Verify

`ntpq -p` reports ntpd's estimate of its *own* error, which is not an independent
check. `Test-LabTime.ps1` measures the clock against the server itself, and works
whether the machine runs ntpd or w32time:

```powershell
.\ntp\Test-LabTime.ps1 -Samples 60
```

Takes about 8 minutes. Read-only, no elevation needed. Want `Result: PASS`.

| Field | Meaning |
| --- | --- |
| `Offset (ms)` | Distance from the reference, with its own uncertainty |
| `Residual Drift (ppm)` | How fast the clock is still gaining or losing. Near zero is the goal. |
| `Drift Quality` | Whether the run was long enough to resolve drift at all |
| `Source Matches Ref` | Catches a machine that was missed during deployment |

Neither offset nor drift is failed on a difference smaller than the measurement
can resolve - see [NOTES.md](ntp/NOTES.md), which explains why that matters more
than it sounds.

Quick daemon-side view any time:

```powershell
C:\NTP\bin\ntpq -p
```

The daily accuracy log lives in `C:\NTP\etc\stats\loopstats.*`.

## Files

| File | Purpose |
| --- | --- |
| `ntp/install-lab-ntp.ps1` | One-shot Meinberg ntpd install. The normal path. |
| `ntp/Test-LabTime.ps1` | Independent verification. Works with ntpd or w32time. |
| `ntp/ntp-advanced.ps1` | Fallback: tunes w32time for machines that cannot run ntpd (~1-2 ms instead of ~50 µs). |
| `ntp/NOTES.md` | Measurements and reasoning behind the configuration. |

## Why not just use Windows' built-in w32time?

It has no driftfile. It relearns the clock's frequency error from scratch on
**every boot**, taking 30-60 minutes to reconverge each time - measured, not
guessed. Lab machines get powered off, so that cost recurs.

`ntp-advanced.ps1` remains available for machines where installing a daemon is
not an option, and gets to roughly 1-2 ms once settled.
