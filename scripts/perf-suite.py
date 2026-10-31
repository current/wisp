#!/usr/bin/env python3
"""Wisp against Vitals, the same scenarios side by side.

    scripts/perf-suite.py                  every scenario, 60 one-second samples each
    scripts/perf-suite.py --samples 120 --only menubar,overview
    scripts/perf-suite.py --wisp build/Wisp.app --out build/perf

Scenarios: both apps in the menu bar with no window, then each app's window on its
overview, CPU, memory and disk pages. Both windows are the same size. Wisp's is
kept off the screen (WISP_BACKGROUND) but told to update as if it were shown;
Vitals' window is moved to the right edge of the screen with only a 24 point
strip showing. Neither app is ever brought forward, so the Mac stays usable. Wisp is relaunched for every scenario; Vitals keeps running
and is switched with its own ⌘1-4 shortcuts (agent-desktop sends them without
bringing it forward).

For each app and scenario: CPU mean, median and 95th percentile, resident memory
at the end, idle wakeups per second and top's energy impact. One `top` run reads
both apps over the same seconds. Writes a Markdown table and a JSON file.
"""

import argparse
import json
import os
import statistics
import subprocess
import time
from datetime import datetime

SCENARIOS = [
    # name, Wisp page (None = no window), Vitals shortcut (None = no window)
    ("menubar", None, None),
    ("overview", "overview", "cmd+1"),
    ("cpu", "cpu", "cmd+2"),
    ("memory", "memory", "cmd+3"),
    ("disk", "disk", "cmd+4"),
]
WIDTH, HEIGHT = 1300, 800


def run(*args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def pid_of(name):
    out = run("pgrep", "-x", name).stdout.split()
    return out[0] if out else None


def screen_width():
    out = run("agent-desktop", "list-displays").stdout
    try:
        return int(json.loads(out)["data"][0]["bounds"]["width"])
    except (ValueError, KeyError, IndexError):
        return 1512


def vitals_window(shortcut):
    """Opens or closes Vitals' window without bringing Vitals forward."""
    if shortcut is None:
        # Its close button: ⌘W only reaches Vitals when it is the active app.
        run("osascript", "-e", 'tell application "System Events" to tell process "Vitals" to '
            'click (first button of window 1 whose subrole is "AXCloseButton")')
        return
    run("open", "-g", "-a", "Vitals")
    time.sleep(2)
    # Parked below Wisp's strip so neither covers the other.
    run("agent-desktop", "move-window", "--app", "Vitals", "--x", str(screen_width() - 24), "--y", "800")
    run("agent-desktop", "press", "--app", "Vitals", shortcut)


def launch_wisp(app, page):
    binary = os.path.join(app, "Contents/MacOS/Wisp")
    run("pkill", "-f", binary)
    time.sleep(1.5)
    # The shipped defaults, whatever this Mac's own settings say.
    env = ["--env", "WISP_MENU_INTERVAL=3", "--env", "WISP_INTERVAL=2"]
    if page:
        env += ["--env", "WISP_BACKGROUND=1", "--env", "WISP_OPEN=window", "--env", f"WISP_PAGE={page}",
                "--env", f"WISP_SIZE={WIDTH}x{HEIGHT}"]
    run("open", "-g", "-n", "-a", app, *env)


def megabytes(text):
    text = text.rstrip("+-")
    unit = text[-1]
    value = float(text[:-1]) if unit in "BKMG" else float(text)
    return value * {"B": 1 / 1048576, "K": 1 / 1024, "M": 1, "G": 1024}.get(unit, 1 / 1048576)


def measure(pids, samples):
    """pids: {pid: name}. Returns {name: {cpu: [...], wakeups: [...], power: [...], memory: MB}}."""
    command = ["top", "-l", str(samples + 1), "-s", "1", "-stats", "pid,cpu,mem,idlew,power"]
    for pid in pids:
        command += ["-pid", pid]
    output = run(*command).stdout
    result = {name: {"cpu": [], "wakeups": [], "power": [], "memory": 0.0} for name in pids.values()}
    # The first block counts since launch, not over the interval.
    for block in output.split("Processes:")[2:]:
        for line in block.splitlines():
            fields = line.split()
            if len(fields) >= 5 and fields[0] in pids:
                entry = result[pids[fields[0]]]
                entry["cpu"].append(float(fields[1]))
                entry["memory"] = megabytes(fields[2])
                entry["wakeups"].append(float(fields[3].rstrip("+-")))
                entry["power"].append(float(fields[4].rstrip("+-")))
    return result


def summary(entry):
    cpu = sorted(entry["cpu"]) or [0.0]
    p95 = cpu[min(len(cpu) - 1, int(round(0.95 * (len(cpu) - 1))))]
    return {
        "cpu_mean": statistics.fmean(cpu), "cpu_median": statistics.median(cpu), "cpu_p95": p95,
        "memory_mb": entry["memory"],
        "wakeups": statistics.fmean(entry["wakeups"] or [0.0]),
        "energy": statistics.fmean(entry["power"] or [0.0]),
        "samples": len(entry["cpu"]),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=60)
    parser.add_argument("--warmup", type=float, default=20)
    parser.add_argument("--only", default="")
    parser.add_argument("--wisp", default=os.path.join(os.path.dirname(__file__), "..", "build", "Wisp.app"))
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "build", "perf"))
    args = parser.parse_args()
    app = os.path.abspath(args.wisp)
    os.makedirs(args.out, exist_ok=True)
    if not pid_of("Vitals"):
        run("open", "-g", "-a", "Vitals")
        time.sleep(5)

    chosen = [s for s in SCENARIOS if not args.only or s[0] in args.only.split(",")]
    results = {}
    for name, page, shortcut in chosen:
        launch_wisp(app, page)
        vitals_window(shortcut)
        time.sleep(args.warmup)
        # By path: other Wisp builds (a worktree, the installed app) may be running too.
        wisp = run("pgrep", "-f", os.path.join(app, "Contents/MacOS/Wisp")).stdout.split()
        pids = {(wisp[0] if wisp else None): "Wisp", pid_of("Vitals"): "Vitals"}
        pids.pop(None, None)
        measured = measure(pids, args.samples)
        results[name] = {app_name: summary(entry) for app_name, entry in measured.items()}
        line = "  ".join(f"{a} {r['cpu_mean']:.2f}% {r['memory_mb']:.0f} MB" for a, r in results[name].items())
        print(f"{name:9} {line}", flush=True)

    # Leave things as they were: Wisp in the menu bar only, Vitals' window closed.
    run("pkill", "-f", os.path.join(app, "Contents/MacOS/Wisp"))
    vitals_window(None)

    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    rows = ["| Scenario | App | CPU mean | CPU median | CPU p95 | Memory | Idle wakeups/s | Energy impact |",
            "|---|---|---:|---:|---:|---:|---:|---:|"]
    for name, apps in results.items():
        for app_name in ("Wisp", "Vitals"):
            r = apps.get(app_name)
            if r:
                rows.append(f"| {name} | {app_name} | {r['cpu_mean']:.2f}% | {r['cpu_median']:.2f}% | {r['cpu_p95']:.2f}% | "
                            f"{r['memory_mb']:.0f} MB | {r['wakeups']:.1f} | {r['energy']:.2f} |")
    table = "\n".join(rows)
    with open(os.path.join(args.out, "perf-suite.md"), "w") as f:
        f.write(f"Measured {stamp}, {args.samples} one-second samples per scenario after {args.warmup:.0f} s warm-up.\n\n{table}\n")
    with open(os.path.join(args.out, "perf-suite.json"), "w") as f:
        json.dump({"measured": stamp, "samples": args.samples, "results": results}, f, indent=2)
    print("\n" + table)


if __name__ == "__main__":
    main()
