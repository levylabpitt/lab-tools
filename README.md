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

On the lab PC, open PowerShell and run:

```powershell
iwr https://raw.githubusercontent.com/levylabpitt/lab-tools/main/ntp/install-lab-ntp.ps1 -OutFile "$env:TEMP\install-lab-ntp.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-lab-ntp.ps1"
```

Click **Yes** on the single UAC prompt. The script prints `SUCCESS` with the
measured clock offset once locked. Expect roughly 20-60 microseconds after ~30
minutes of settling (measured: 22 us mean on a wired connection).

Afterwards, check status on any machine with:

```powershell
C:\NTP\bin\ntpq -p
```

The daily accuracy log lives in `C:\NTP\etc\stats\loopstats.*`.

`ntp/ntp-advanced.ps1` is the fallback for machines that cannot run the NTP
daemon: it tunes Windows' built-in w32time instead (expect ~1-2 ms rather than
~50 us).
