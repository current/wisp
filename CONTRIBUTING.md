# Contributing

Bug reports and pull requests are welcome. Open an issue first for anything
larger than a fix, so we can agree on the approach before you write it.

## Build and test

Xcode 16 or later, on Apple silicon:

```sh
swift test                    # unit tests
scripts/build-app.sh --debug  # build/Wisp.app, quick debug build
scripts/build-app.sh          # release build, used for performance numbers
```

The code is split into `Sources/WispCore` (sampling, history, cleaning; no
AppKit), `Sources/WispApp` (the app) and `Sources/WispCLI` (the `wisp` command
and MCP server).

## Performance

Wisp is a monitor, so it must not slow the Mac down itself. Measure a release
build before and after any change that runs while the app is open, with
`scripts/perf-suite.py` or the steps in
[docs/performance.md](docs/performance.md), and put the numbers in the pull
request. Work for a page runs only while that page is open.

## Cleaning code

Anything that removes files goes through `Cleaner` in
`Sources/WispCore/Cleaning/Cleaner.swift`, which moves items to the Trash and
refuses paths outside the rules in `CleanPathRules`. Scanners only read the
disk. Tests use temporary home folders. Never point a test at your real one.

## Style

Match the code around you. Comments explain why, not what. Commit messages are
short and imperative.
