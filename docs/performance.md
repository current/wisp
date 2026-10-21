# Performance

Measured on 3 November 2026 on an M3 Max MacBook Pro (36 GB, macOS 27.2) with a
release build. Each row is 120 one-second samples from one shared `top` run, so
all three apps were measured over the same seconds. CPU is percent of one core.

## Menu bar only

Wisp shows CPU, memory and network in the menu bar. Nothing else is open.

| App    | Mean  | Median | p95  | Max   | Memory |
|--------|-------|--------|------|-------|--------|
| Wisp   | 0.09% | 0.00%  | 0.5% | 0.7%  | 18 MB  |
| Vitals | 1.79% | 0.00%  | 7.0% | 16.7% | 412 MB |
| Stats  | 1.36% | 1.30%  | 2.5% | 2.8%  | 187 MB |

## Wisp window open on Apps

The window is in front and redraws every two seconds. Vitals and Stats were
running in the background at the same time, so their rows look the same as
above. With its own window open, Vitals measured 3.6 to 4.9% earlier the same
day.

| App    | Mean  | Median | p95  | Max   | Memory |
|--------|-------|--------|------|-------|--------|
| Wisp   | 1.60% | 1.20%  | 5.6% | 6.2%  | 55 MB  |
| Vitals | 1.83% | 0.00%  | 7.2% | 16.6% | 212 MB |
| Stats  | 1.34% | 1.30%  | 2.4% | 2.8%  | 187 MB |

My target for the open window was 0.5%. Wisp does not reach it yet. Collecting
the data costs about 3 ms per tick on a background queue. The rest is AppKit
drawing on the main thread, mostly the table layout when the rows are re-sorted.
That happens at most every six seconds.

## What keeps it cheap

- One timer drives all work. Each job runs only when something on screen needs
  it, and only at that thing's interval. With the window closed, the menu bar
  updates every three seconds and processes are scanned every ten, for history
  and alerts. Turn both off and Wisp stops scanning processes.
- A full process scan (`proc_listpids`, then `proc_pid_rusage` per process)
  takes about 1.1 ms. Names, paths and app grouping are cached by pid and start
  time, so they are looked up once per process.
- Per-app network comes from the NetworkStatistics framework in about 2 ms.
  `nettop` would cost more than a full core.
- Power comes from IOReport energy counters, read in-process. Nothing runs as
  root and Wisp starts no child processes.
- Each menu bar item is drawn into one bitmap and replaced only when its text
  changes. Separate text fields and images cost about 2 ms per redraw.
- Table cells are laid out by hand and draw their own text. A new value marks
  one cell for redraw and does not re-lay out the window.
- History is one ring buffer per app in memory. It is written to SQLite once an
  hour, which takes under a millisecond.

## Running the benchmark

```sh
scripts/build-app.sh
open build/Wisp.app
scripts/benchmark.py                 # Wisp, Vitals and Stats, 120 samples
scripts/benchmark.py --samples 300 --apps Wisp,Stats
```

`top` counts CPU since launch in its first sample, so the script drops it. Let
an app run for a few seconds after launch before you measure it.
