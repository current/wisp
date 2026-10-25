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
  and battery, as text or a small graph. Click it for a dashboard: CPU with a
  live line, six meters, a heat map of every core or memory by kind, and the
  busiest apps.
- **Overview:** one card per part of the machine with the last half hour as
  bars, and a list of anything worth a look.
- **Apps:** processes grouped into the app that owns them, with CPU, memory,
  power, disk and network per app. Select one to see its processes, code
  signature and the last hour.
- **CPU, Memory, GPU, Neural Engine, Power, Disk, Network:** a live, hourly or
  daily chart, the figures behind it, and the apps that used the most. CPU has
  the core map, Memory the breakdown by kind, Disk every volume, Network the
  totals for today, the week and the month, and Power the battery and what is
  keeping the Mac awake.
- **Sound and Bluetooth:** output and input devices with their volume, the apps
  playing or recording, and paired devices with their battery.
- **Sensors:** temperatures and fans.
- **Projects:** every project folder with something running in it, its servers
  and ports, and the Docker containers that belong to it. Wisp marks servers
  nobody has connected to for 30 minutes and can stop them.
- **Containers:** CPU, memory, network and disk per container, what Docker
  keeps on disk, and stop or restart. Wisp talks to the engine socket directly
  and works with Docker Desktop, OrbStack, Colima, Rancher Desktop and Lima.
- **Coding Agents:** Claude Code, Codex, Gemini CLI, Aider and other agents,
  with the folder each works in and what it costs. If you turn it on, the
  5-hour and weekly limits of each Claude and Codex account, and the tokens
  Claude Code used today.
- **Alerts:** a notification when an app holds a core for minutes, grows by a
  gigabyte of memory in half an hour, keeps writing to disk or the network, or
  goes over a limit you set for it, and when the CPU runs hot. Settings keeps
  the recent ones.

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

`wisp mcp` runs an MCP server on stdin and stdout, so an assistant can ask what
is slowing the machine down. For Claude Code:

```sh
claude mcp add wisp -- /usr/local/bin/wisp mcp
```

It reads the same figures the CLI prints. The one thing it can ask for is to
quit an app: Wisp then shows you the app, what it uses and the assistant's
reason, and quits it only if you click Quit. It cannot kill processes or change
settings. To turn it off, clear Assistants in Settings, General.

## Privacy

Wisp reads everything on your Mac and sends nothing anywhere. History lives in
`~/Library/Application Support/Wisp`. It has no updater and no analytics.

The one exception is off until you turn it on: plan limits on the Coding Agents
page. Wisp then reads the sign-in that Claude Code keeps in your Keychain (through
the `security` tool, which Claude Code itself uses) and the one Codex keeps in
`~/.codex/auth.json`, and sends each only to the company that issued it, every
five minutes while the page is open. It never stores, refreshes or logs them.

## License

MIT. See [LICENSE](LICENSE). The IOReport channel names for CPU power on
recent Macs come from [macmon](https://github.com/vladkens/macmon), also MIT;
see [NOTICE](NOTICE).
