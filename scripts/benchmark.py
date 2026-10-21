#!/usr/bin/env python3
"""Measure what Wisp and other monitors cost while they run.

    scripts/benchmark.py                       Wisp, Vitals and Stats, 120 one-second samples
    scripts/benchmark.py --samples 300
    scripts/benchmark.py --apps Wisp,Vitals    any process names

All processes are read by one `top -l N -s 1` run, so every app is measured over
the same seconds: a busy moment lands on all of them or none. top's first sample
counts CPU since launch, not over the interval, so it is dropped.
"""

import argparse
import statistics
import subprocess


def pids(name):
    out = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout.split()
    return [p for p in out if p]


def megabytes(text):
    text = text.rstrip("+-")
    unit = text[-1]
    value = float(text[:-1]) if unit in "BKMG" else float(text)
    return value * {"B": 1 / 1048576, "K": 1 / 1024, "M": 1, "G": 1024}.get(unit, 1 / 1048576)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=120)
    parser.add_argument("--apps", default="Wisp,Vitals,Stats")
    args = parser.parse_args()

    names = {}
    for name in args.apps.split(","):
        for pid in pids(name):
            names[pid] = name
    if not names:
        raise SystemExit("none of those apps is running")

    command = ["top", "-l", str(args.samples + 1), "-s", "1", "-stats", "pid,cpu,mem"]
    for pid in names:
        command += ["-pid", pid]
    output = subprocess.run(command, capture_output=True, text=True).stdout

    cpu = {name: [] for name in names.values()}
    memory = {}
    blocks = output.split("Processes:")[2:]
    for block in blocks:
        totals = {}
        for line in block.splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[0] in names:
                name = names[fields[0]]
                totals[name] = totals.get(name, 0.0) + float(fields[1])
                memory[(name, fields[0])] = megabytes(fields[2])
        for name, value in totals.items():
            cpu[name].append(value)

    print(f"{len(blocks)} samples, one second apart\n")
    print(f"{'app':<10} {'mean':>7} {'median':>7} {'p95':>7} {'max':>7} {'memory':>9}")
    for name, values in cpu.items():
        if not values:
            continue
        ordered = sorted(values)
        p95 = ordered[max(0, int(round(0.95 * len(ordered))) - 1)]
        mem = sum(v for (n, _), v in memory.items() if n == name)
        print(f"{name:<10} {statistics.mean(values):>6.2f}% {statistics.median(values):>6.2f}% {p95:>6.1f}% {max(values):>6.1f}% {mem:>7.0f} MB")
    print("\nCPU is percent of one core. Memory is top's MEM column (physical footprint), summed over the app's processes.")


if __name__ == "__main__":
    main()
