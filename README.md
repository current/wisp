# Wisp

Wisp is a system monitor for macOS. It sits in the menu bar and shows which apps
use your CPU, memory, energy, disk and network. It keeps each app's last day
minute by minute and a year of hourly totals. It also lists the dev servers,
Docker containers and coding agents you have running.

With only the menu bar showing, Wisp uses about 0.1% of one core and 18 MB of
memory. [docs/performance.md](docs/performance.md) has the measurements and how
to repeat them.

## What it shows

- **Menu bar:** any mix of CPU, memory, network, disk, GPU, temperature, power
  and battery, as text or a small graph. Click it for a dashboard and the five
  busiest apps.
- **Apps:** processes grouped into the app that owns them, with CPU, memory,
  power, disk and network per app. Select one to see its processes, code
  signature and the last hour.
- **CPU, Memory, Energy, Disk, Network, GPU:** a 24-hour chart for the machine
  and the apps that used the most over that time.
- **Sensors:** temperatures, fans, battery and the charge of Bluetooth
  accessories.
- **Ports:** servers listening on a port, grouped by project folder. Wisp marks
  the ones nobody has connected to for 30 minutes.
- **Docker:** running containers with CPU, memory and ports. Wisp talks to the
  engine socket directly and works with Docker Desktop, OrbStack, Colima and
  Rancher Desktop.
- **Agents:** Claude Code, Codex, Gemini CLI, Aider and other coding agents, with
  the folder they work in and every process they started.
- **Alerts:** a notification when an app holds a core for minutes, grows by a
  gigabyte of memory in half an hour, or keeps writing to disk or the network.
  You set the limits.

## Requirements

macOS 15 or later on Apple silicon. Power readings and some sensors are not
available on Intel Macs.

## Build

You need Xcode 16 or later.

```sh
scripts/build-app.sh          # universal release build in build/Wisp.app
scripts/build-app.sh --debug  # faster, for this machine only
open build/Wisp.app
```

## Command line

The app bundle includes a `wisp` command. Link it somewhere on your PATH:

```sh
ln -s "$PWD/build/Wisp.app/Contents/Helpers/wisp" /usr/local/bin/wisp
```

```
wisp status            the machine now and the five busiest apps
wisp apps --sort memory
wisp app Safari        one app, its processes and the last hour
wisp ports             dev servers by project
wisp agents
wisp docker
wisp alerts
```

Add `--json` to any command for output you can pipe into `jq`. While the app is
running, `wisp` asks it over a local socket and gets an answer in a few
milliseconds. Without the app, `wisp` takes its own one-second sample.

## MCP server

`wisp mcp` runs a read-only MCP server on stdin and stdout, so an assistant can
ask what is slowing the machine down. For Claude Code:

```sh
claude mcp add wisp -- /usr/local/bin/wisp mcp
```

It can read the same figures the CLI prints and cannot kill processes or change
settings. To turn it off, clear Assistants in Settings, General.

## Privacy

Wisp reads everything on your Mac and sends nothing anywhere. History lives in
`~/Library/Application Support/Wisp`. It has no updater, no analytics and no
network code beyond the Docker socket on your machine.

## License

MIT. See [LICENSE](LICENSE). The IOReport channel names for CPU power on
recent Macs come from [macmon](https://github.com/vladkens/macmon), also MIT;
see [NOTICE](NOTICE).
