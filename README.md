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
iwr https://raw.githubusercontent.com/levylabpitt/lab-tools/main/lab-ntp/install-lab-ntp.ps1 -OutFile "$env:TEMP\install-lab-ntp.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-lab-ntp.ps1"
```

Click **Yes** on the single UAC prompt. The script prints `SUCCESS` with the
measured clock offset once locked. Expect roughly 20-60 microseconds once
settled.

**On a first install, settling takes hours, not minutes.** With no driftfile
yet, ntpd has to learn the crystal's frequency error from zero; a machine 51 ppm
out took about 3 hours to come inside 1 ms. Restarts after that resume from the
driftfile and settle in ~30 minutes. A millisecond-scale offset on day one is
normal, and `test-lab-ntp.ps1` reports it as `IMPROVING` rather than `FAIL` while
it is still closing.

Point it somewhere else with `-NtpServer <host|ip>` if you need to.

For scripted deployment, add `-NoPause` and check the exit code - `0` is
success, and each failure has its own code (`3` cannot resolve, `4` server not
answering, `5` install failure, `6` bad installer, `7` installed but never
locked, `8` wrong script for this machine). Both scripts use the same table.

### Verify

`ntpq -p` reports ntpd's estimate of its *own* error, which is not an independent
check. `test-lab-ntp.ps1` measures the clock against the server itself, and
works whether the machine runs ntpd or w32time:

```powershell
.\lab-ntp\test-lab-ntp.ps1 -Samples 60
```

Takes about 8 minutes; the default 30 samples takes 4 and still measures offset
well, but often will not resolve drift. Read-only, no elevation needed. Want
`Result: PASS`.

| Field | Meaning |
| --- | --- |
| `Result` | `PASS`, `IMPROVING`, or `FAIL` |
| `Issues` | Real problems. Any entry means not-PASS. |
| `Notes` | What the run could not determine. Never affects `Result`. |
| `Offset (ms)` | Distance from the reference, with its own uncertainty |
| `Residual Drift (ppm)` | How fast the clock is still gaining or losing. Near zero is the goal. |
| `Drift Quality` | Whether the run was long enough to resolve drift at all |
| `Offset Trend (ms/h)` | Which way the offset is moving, from hours of history. Negative is closing. |
| `ETA to Tolerance (h)` | At the current rate, when it comes inside `-ToleranceMs` |
| `Source Matches Ref` | Catches a machine that was missed during deployment |

`IMPROVING` means the offset is the only thing wrong and it is measurably
closing with an end in sight. It reads ntpd's own `loopstats`, which holds one
line per clock update going back to install, so it can see a trend no single run
could. The verdict itself still rests on the independent measurement; the
history only answers "which direction, and how fast". Machines on w32time have
no loopstats, so runs are also appended to
`C:\ProgramData\LevyLab\lab-sync-history.csv` as a fallback (best-effort, still
no elevation needed; `-NoHistory` disables it).

The gate is deliberately narrow. Anything unlocked, on the wrong source, or
drifting badly is `FAIL` regardless of which way its offset is moving, and so is
anything still hours away from tolerance - that is stuck, not converging.

**For lab sweeps, test `Result -ne 'PASS'` rather than `-eq 'FAIL'`.**

Neither offset nor drift is failed on a difference smaller than the measurement
can resolve, and a run that resolves nothing reports that in `Notes` rather than
failing the machine - see [NOTES.md](lab-ntp/NOTES.md), which explains why that
matters more than it sounds.

Quick daemon-side view any time:

```powershell
C:\NTP\bin\ntpq -p
```

The daily accuracy log lives in `C:\NTP\etc\stats\loopstats.*`.

## Files

| File | Purpose |
| --- | --- |
| `lab-ntp/install-lab-ntp.ps1` | One-shot Meinberg ntpd install. The normal path. |
| `lab-ntp/test-lab-ntp.ps1` | Independent verification. Works with ntpd or w32time. |
| `lab-ntp/tune-w32time.ps1` | Fallback only: tunes w32time for machines that cannot run ntpd (~1-2 ms instead of ~50 µs). |
| `lab-ntp/NOTES.md` | Measurements and reasoning behind the configuration. |

## Why not just use Windows' built-in w32time?

It has no driftfile. It relearns the clock's frequency error from scratch on
**every boot**, taking 30-60 minutes to reconverge each time - measured, not
guessed. Lab machines get powered off, so that cost recurs.

`tune-w32time.ps1` remains available for machines where installing a daemon is
not an option, and gets to roughly 1-2 ms once settled. It is strictly the
worse option - reach for it only when `install-lab-ntp.ps1` is off the table.

It refuses to run on a machine that already has the ntp service, since
re-enabling w32time beside ntpd would leave two daemons disciplining one clock
and both would report themselves healthy. To move a machine back to w32time on
purpose, pass `-Force`, which stops and disables ntpd first.

## License

BSD 3-Clause - see [LICENSE](LICENSE). Use it freely; the one condition beyond
attribution is that the LevyLab name not be used to endorse derived products.
