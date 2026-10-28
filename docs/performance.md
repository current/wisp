# Performance

Measured on 3 November 2026 on an M3 Max MacBook Pro (36 GB, macOS 27.2) with a
release build. Each run takes one-second samples from one shared `top` run, so
every app in a table was measured over the same seconds. CPU is percent of one
core.

## Menu bar only

Wisp shows CPU and memory in the menu bar. Nothing else is open. Two runs on
the same day, 120 and 90 samples; the spread between them is about what
separate runs vary by.

| App    | Mean        | Median | p95       | Max        | Memory        |
|--------|-------------|--------|-----------|------------|---------------|
| Wisp   | 0.09–0.25%  | 0.00%  | 0.5–1.5%  | 0.7–1.8%   | 18 MB         |
| Vitals | 1.31–1.79%  | 0.00–0.10% | 5.7–7.0% | 13.8–16.7% | 249–412 MB |
| Stats  | 1.26–1.36%  | 1.20–1.30% | 2.3–2.5% | 2.5–2.8%   | 187 MB        |

## With something open

Wisp only, 60 to 90 samples each, updating every two seconds. With its own
window open, Vitals measured 3.6 to 4.9% the same day.

| Wisp showing          | Mean  | Median | p95  | Memory |
|-----------------------|-------|--------|------|--------|
| Dashboard (menu bar)  | 2.35% | 3.55%  | 5.2% | 37 MB  |
| Overview              | 1.95% | 2.80%  | 4.0% | 41 MB  |
| CPU page              | 2.30% | 3.10%  | 5.1% | 44 MB  |
| Coding Agents page    | 1.54% | 1.90%  | 3.4% | 56 MB  |

After the custom window (floating glass sidebar, app drawer, per-app GPU time),
40 to 60 samples each with the machine busy (CPU 50 to 60% from other apps):

| Wisp showing                  | Mean  | Median | p95  | Memory |
|-------------------------------|-------|--------|------|--------|
| Overview                      | 2.5–2.8% | 3.1–4.0% | 5.5–6.1% | 50 MB |
| Apps page                     | 4.8%  | 5.3%   | 12%  | 62 MB  |
| CPU page with the app drawer  | 4.2%  | 5.5%   | 8.4% | 65 MB  |
| Same, motion turned off       | 3.5%  | 4.5%   | 6.9% | 62 MB  |

The drawer re-reads the app's processes, their command lines (cached by pid)
and the GPU time of each driver client every tick, about 1.5 ms. The digit
pop-ins cost about 0.7% of a core while the drawer is open.

The dashboard's cost is about a third the process scan behind its app list
(one `proc_pid_rusage` call per process, around 6 ms for 740 processes), a
third drawing, and a third Core Animation committing the changes.

Animations go through Core Animation as position and opacity changes, which
the window server runs. An earlier build rolled the numbers with
`CATransition`, which renders snapshots inside the app through Metal: the
dashboard then held 241 MB instead of 37 MB.

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
- The card pages draw their own views and lay them out by frame. A new reading
  redraws only the view whose value changed.
- Anything that makes Core Animation render a layer tree inside the app costs
  about 190 MB of Metal buffers. Found so far: `CATransition`, `masksToBounds`
  on a rounded view with content, a shadow without a `shadowPath` (on every
  clickable card it held 300 MB and tripled the overview's CPU), and AppKit
  switching a view that redraws often to asynchronous drawing. Charts therefore
  draw into their own bitmap (`BitmapView`), and hover feedback is a border
  colour, not a shadow. `WISP_DRAWER=<app> WISP_DUMP_LAYERS=1` lists any layer
  that still draws asynchronously.
- Motion is transform and opacity animations on small bitmaps: a number change
  pops only the digits that changed, then folds them back into one bitmap. The
  drawer and the page move together one layout per screen refresh for 0.3 s and
  nothing runs once they settle.
- The dashboard is a plain borderless panel. An `NSPopover` with its vibrant
  material held about 190 MB of graphics memory whenever anything in it moved.

## Running the benchmark

```sh
scripts/build-app.sh
open build/Wisp.app
scripts/benchmark.py                 # Wisp, Vitals and Stats, 120 samples
scripts/benchmark.py --samples 300 --apps Wisp,Stats
```

`top` counts CPU since launch in its first sample, so the script drops it. Let
an app run for a few seconds after launch before you measure it.
