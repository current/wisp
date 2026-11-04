# Changelog

## 0.2.0 (4 November 2026)

New:

- **Why is it slow?** A button on Overview checks memory pressure, swap, busy
  processes, Spotlight indexing and what you left running, and says what it
  found in a sentence with a button to the app. Also as a menu bar dashboard
  block, `wisp why` and an MCP tool.
- **Labelled spikes.** Hour and Day charts name the app behind each spike.
- **Storage page.** Where the disk space goes: a whole-disk bar, what System
  Data is made of, developer folders (node_modules, DerivedData, Rust targets,
  VM disks), items you can move to the Trash after a confirmation, a folder
  drill-down, free space over 30 days and SSD health. The app drawer gets a
  Storage section. Also `wisp storage` and an MCP tool. Scans run only while
  the page is open.
- **Battery page.** Health, charge history, energy per app and what keeps the
  Mac awake. Replaces the Power page; desktop Macs keep a Power page.
- **Login & Background page.** Launch agents, daemons and app helpers with who
  made them, when they run and what they cost. Flags leftovers from deleted
  apps and helpers that keep restarting.
- **Network per app.** The drawer lists an app's connections by host, its
  listening ports and the data it used today, this week and this month. The
  Network page adds Most data and Hosts.

Changed:

- Plan limits no longer read the Claude Code or Codex sign-in, and Wisp makes
  no requests for them. Claude Code's limits come from its status line (yours
  keeps working), Codex's from its session logs. If you had plan limits on,
  click Connect on the Coding Agents page.
- A second click on the menu bar item closes the dashboard.
- The app drawer stays open when the Apps list re-sorts.
- Striped rows in every table.

## 0.1.0 (31 October 2026)

First release.
