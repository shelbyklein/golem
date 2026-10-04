# Performance evidence

The accepted run is `golem-animation-performance-schedule.json` plus its `.services.json` sampler. Three visible and three hidden native runs each exceed 60 seconds. Superseded attempts are diagnostics and do not establish acceptance.

| Scenario | Median CPU percent |
| --- | ---: |
| Legacy combined UI | 6.047 |
| Chatterbox UI alone | 0.006 |
| Golem visible | 6.588 |
| Golem hidden | 0.081 |

Conservative combined visible estimate: 6.627% = Golem median + maximum concurrent service sample (0.033%) + measured Chatterbox UI median. Budget: 6.652% (legacy median + 10%). It passes narrowly; this is a controlled idle fixture, not a battery-life or real-provider workload claim. All hidden runs recorded **zero** rig draws. Visible runs recorded 721, 722, 722 draws; they are valid animated samples.

Chat switching: median 21.06 ms and p95 24.41 ms versus 24.29/25.94 ms baseline. Median stall total over each half-second observation is 478.55 ms versus 488.55 ms; no >10% regression. Absolute stall totals are affected by timer scheduling under load and should not be described as literal continuous freezes.

Headless service samples in `headless-performance.json` are below ps centisecond resolution, not literally zero CPU. No UI/animation source is linked into service targets. RSS/wakeup and physical-device energy comparisons remain unverified; CPU measurements alone do not establish those properties.

Build: optimized (`-O`) Debug Golem with custom timer schedule, 12 fps idle / 24 fps active, visibility gating, and one animated avatar when the mini is showing. No real automation, production data, paid providers or push delivery were used.
