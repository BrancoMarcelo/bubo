# Vendored sensor layer

`IOReportWrapper.{h,m}` and `SMC.{c,h}` are taken unmodified from
[ryyansafar/MacMonitor](https://github.com/ryyansafar/MacMonitor) (MIT — see
`LICENSE.MacMonitor`). They cover everything macOS has no public API for:

| From here | Interface |
|---|---|
| CPU/GPU/ANE/DRAM power, E/P/S cluster active % + MHz, GPU usage + MHz, DRAM bandwidth | `IOReport` (private, no root) |
| CPU/GPU temps, die hotspot, fan RPM, board power (PSTR) | `AppleSMC` + `IOHIDEventSystemClient` (no root) |

Everything else in Bubo (CPU %, memory, swap, processes, battery, network,
disk I/O) uses public APIs and lives in `Bubo.swift`.

Not every key exists on every chip — an M1 returns 0 for DRAM power and PSTR, so
the UI hides a rail that reads exactly 0 rather than printing a fake 0.0 W.

To update: re-copy the four files from upstream. They have no Bubo-specific edits.
