# Timekeeping notes

Why the scripts in this folder do what they do. Reference material, not instructions.

Measured on a lab workstation (AMD B450 chipset, Realtek gigabit NIC, Windows 11 build 26200) against the lab's LeoNTP GPS appliance, July 2026.

## Why ntpd rather than Windows' w32time

**w32time does not persist the clock's frequency correction.** Every registry value under `HKLM\SYSTEM\CurrentControlSet\Services\W32Time` was inspected: `Config` holds only loop *tuning parameters* (`FrequencyCorrectRate`, `PhaseCorrectRate`, `PollAdjustFactor`, `HoldPeriod`), and `LastKnownGoodTime` is a timestamp. Nothing stores what the loop has *learned*.

So on every boot w32time starts with no correction applied and rebuilds the estimate one poll at a time. Measured reconvergence on this hardware:

| Elapsed since boot | Residual drift | Offset |
| --- | --- | --- |
| 10 min | 16.1 ppm | 3.6 ms |
| 25 min | 0.87 ppm | 1.2 ms |
| 60 min | 0.35 ppm | < 0.1 ms |

For machines that get powered off regularly, that is a recurring 30-60 minute window of degraded accuracy. `ntpd`'s `driftfile` eliminates it - a restart resumes at the known correction.

That is the decisive reason. Most of `ntpd`'s other sophistication (source selection, clustering, clock filtering) exists to arbitrate among several distant, disagreeing servers, and does very little when there is one GPS stratum-1 source a single hop away.

## What the clock actually does

Free-running drift on this machine measured **35.4 ppm** (about 3.06 s/day) by three independent methods. Once disciplined, w32time settled on an applied correction of 35.5 ppm and held offset under 0.2 ms.

The applied correction crept 35.5 → 35.7 ppm over 18 hours. That is temperature: crystal frequency varies with it. A one-time correction cannot track that; continuous discipline can. It also means a saved driftfile value is a good *starting estimate*, not a permanent answer.

## The measurement trap

**Short measurement windows produce confident nonsense.** At 35 ppm the clock moves only ~0.5 ms in 14 seconds, well below the jitter on a typical network path. Early attempts to measure drift gave 44 ppm, then 40 ppm, and one run produced the wrong *sign* entirely (-5.65 ppm). The true value was 35.4.

`test-lab-ntp.ps1` therefore computes the standard error of the regression slope and of the mean offset, reports both, and **will not fail a clock on a difference smaller than the measurement can resolve.** Two sigma is the margin.

The same principle governs a run that resolves nothing at all. A window too short to separate drift from network jitter is a fact about the measurement, not about the clock, so `Drift Quality` of `Poor` or `Insufficient` lands in `Notes` and leaves `Result` alone. Only `Issues` decides PASS/FAIL. An earlier version failed on it, which meant a noisy path or a short run condemned a healthy machine - the identical error the two-sigma margins were added to prevent, arriving through a different door.

The correction has to stop there, though. `Drift Quality` is informational, but the drift *magnitude* test still runs on every sample set, because the two-sigma margin already handles an imprecise run by absorbing it. A first attempt at the fix gated the magnitude check behind the quality label, which conflates how precisely the slope was measured with how large it is. That swallowed a genuine 51.34 ± 5.69 ppm on the machine described below - nine sigma from zero, a clock that had never been disciplined at all - purely because the uncertainty exceeded 5 ppm. Precision and magnitude are separate questions and need separate tests.

This matters in both directions. An early version failed a healthy machine on an offset of 1.21 ms against a 1.00 ms threshold while its own sample spread was 7.2 ms - crying wolf on 0.2 ms it could not actually see.

For drift precision, window length beats sample count: 60 samples at 8 s resolves the slope about as well as 150 samples at 2 s, using 60% fewer packets.

## restrict applies to the server's replies

The first machine deployed with `install-lab-ntp.ps1` never synchronised once, over three days, while looking completely healthy: service running, start mode Automatic, correct IP in `ntp.conf`, and the appliance answering raw NTP probes from that same machine on demand. `ntpq -pn` showed the tell:

```
 10.226.177.233  .INIT.   16 u    -   64    0    0.000   +0.000   0.000
```

`.INIT.` with `reach 0` means ntpd had never processed a single reply. The cause was the generated config:

```
restrict default kod nomodify notrap nopeer noquery noserve
```

**`restrict` filters incoming packets, and a server's reply to our own request is an incoming packet.** With no line permitting the upstream, every answer was discarded before ntpd looked at it. Adding one line fixed it instantly - `reach` climbed and ntpd stepped the clock from 7752.9 ms to 1.271 ms.

The clock had free-run the whole time at 51.34 ppm. That is the arithmetic that identified it: 7.7529 s at 51.34 ppm is 1.75 days, matching install to discovery exactly. A residual drift near the machine's *free-running* figure means nothing is disciplining the clock, whatever the service status says.

Two lessons worth keeping. Hardening templates that use a restrictive default always whitelist their upstream servers, and the widely copied `restrict default kod nomodify notrap nopeer noquery` omits `noserve` for this reason. And a time daemon reports itself healthy while doing nothing at all, which is the entire argument for `test-lab-ntp.ps1` measuring against the reference independently rather than asking the daemon how it is doing.

## First convergence takes hours, and gets worse before it gets better

Measured from `loopstats` on the first machine to sync correctly, from a cold start with no driftfile:

| Elapsed | Offset | Drift correction applied |
| --- | --- | --- |
| 5 min | 4.05 ms | 0.00 ppm |
| 10 min | -7.22 ms | 0.00 ppm |
| 20 min | 10.73 ms | 4.34 ppm |
| **30 min** | **16.19 ms** | 6.59 ppm |
| 45 min | 8.09 ms | 1.06 ppm |
| 60 min | 9.20 ms | 9.72 ppm |
| 90 min | 5.05 ms | 21.06 ppm |
| 120 min | 3.06 ms | 27.98 ppm |
| 150 min | 1.37 ms | 31.67 ppm |
| 175 min | 0.90 ms | 33.13 ppm |

**The offset peaks around 30 minutes, roughly four times worse than it started.** That is not a fault. ntpd begins with a frequency correction of zero, so while it is still learning, the clock keeps running away at its full 51 ppm and ntpd is chasing a moving target. Only once the applied correction approaches the true error does the offset collapse. Anyone who checks at the half-hour mark and sees a growing offset is looking at normal behaviour at its worst moment.

Crossing inside 1 ms took about 3 hours, and the correction was still climbing toward the machine's measured 51.34 ppm when it got there. The old claim of "~30 min to converge" was wrong for a first install; it is about right for a *restart*, because the driftfile supplies the frequency and only the phase has to settle.

This is what makes `Result: IMPROVING` worth having. A first-day machine is genuinely out of tolerance and genuinely fine, and those two facts need to be reportable at the same time.

## Poll the server gently

Sampling every 2 s can trip an NTP server's rate limiting. Symptoms are dropped samples (runs returning 141 of 150) and occasionally a stalled `w32tm /stripchart` that never returns. Default `-PeriodSeconds` is 8 for that reason, and every wait in the script is bounded so a stalled server can never hang the run.

## Secure Time Seeding

Windows estimates time from TLS handshakes as a fallback for a grossly wrong clock, enabled by default since Windows 10 1511. The feature reads a handshake field that many modern TLS stacks fill with **random bytes**, and has produced [documented corrections wrong by days, weeks, or years](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/sts-recommendations-for-windows-server).

Microsoft now ships Windows Server 2025 with it off. `tune-w32time.ps1` sets `UtilizeSslTimeData = 0`; the change needs a reboot to take effect. Installing ntpd disables w32time entirely, so the question does not arise.

One machine here returned from a 6.3-day power-off **12.3 days behind** - roughly double the downtime, which RTC drift cannot explain. Never proven, but it fits.

## Microsoft's stated requirements for 1 ms

Relevant to the fallback path. All must hold:

- Better than **0.1 ms one-way network latency** to the source
- **4 or fewer network hops**
- Stratum 5 or closer, W32Time startup type Automatic
- Windows 10 / Server 2016 or newer throughout

Measured against candidate sources:

| Source | RTT | Hops | Sample spread | Meets 1 ms? |
| --- | --- | --- | --- | --- |
| time.windows.com | 26 ms | 14+ | 3.6 ms | No |
| time.nist.gov | 35 ms | 14+ | 0.24 ms | No |
| pool.ntp.org | 62 ms | - | 1.2 ms | No |
| Campus NTP server | 1-4 ms | 10 | 0.1-12 ms | No |
| **Lab GPS appliance** | **<1 ms** | **1** | **<10 µs** | **Yes** |

The public servers all agreed within ~4 ms of each other, so the network was healthy. They are simply 130-300x over the latency budget. **The time source, not client tuning, is what puts 1 ms out of reach on the public internet.**

The appliance answers a raw NTP query as stratum 1, reference ID `GPS`, leap indicator 0, precision 2^-25 (29.8 ns), root delay and dispersion both zero. `w32tm /stripchart` does not report stratum or reference ID - that needs a raw 48-byte client packet to UDP 123, with stratum at byte 1 and reference ID at bytes 12-15.

## Hardware limits on this class of machine

| Component | Measured | Limit imposed |
| --- | --- | --- |
| `GetSystemTimeAdjustmentPrecise` | 0.1 ppm granularity | 6.4 µs per 64 s poll. Negligible. |
| QPC frequency | 10 MHz (100 ns) | Negligible |
| NIC | Consumer gigabit, no PTP timestamping | Software timestamping is the real floor |

`GetSystemTimeAdjustmentPrecise` is not exported from `kernel32.dll` despite the documentation; it resolves from `api-ms-win-core-sysinfo-l1-2-4.dll`. Its `Disabled` flag reading `False` is the cleanest single proof that the kernel is actively slewing the clock rather than free-running.

Going below ~50 µs would need an IEEE 1588-capable NIC and PTP. Windows PTP support is substantially weaker than Linux's - verify availability before purchasing.

For instrument data specifically, the most robust approach is not to trust the OS clock at all: take timestamps from a GPS/PPS source or the instrument's own clock, and record the OS-clock offset alongside them.

## References

- [Configuring systems for high accuracy](https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/configuring-systems-for-high-accuracy)
- [Support boundary for high accuracy time](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/support-boundary-high-accuracy-time)
- [W32Time registry reference](https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings)
- [Meinberg: troubleshooting w32time](https://www.meinbergglobal.com/english/info/ntp-w32time.htm)
