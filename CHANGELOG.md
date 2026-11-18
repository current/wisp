# Changelog

## 0.3.0, 18 November 2026

Added:

- Clean Up page with Junk, Developer, Large Files, Leftovers, Uninstall and
  History tabs. Items go to the Trash after a review. Simulators, local
  snapshots and Homebrew casks are removed by their own tools, listed apart.
  Folders in use, dirty git repositories and open apps are skipped.
- `wisp clean` and `wisp uninstall APP`, which list by default and remove with
  `--apply`. MCP tools `list_cleanable` and `uninstall_plan`, which only list.
- Uninstall button in the app drawer.
- Scheduled clean and a deleted-app watcher in Settings, both off by default.
- A menu bar item for AI plan usage. It shows a Claude or Codex limit (5-hour,
  weekly or both) for one account or the one closest to its limit. It turns red at 90% and opens
  every account's limits and reset times. Accounts used through T3 Code are
  read from T3 Code's logs.
- Clicking a menu bar item opens a dropdown about its reading. The Memory item
  shows memory and the apps using the most of it; Network shows the apps moving
  data. Settings, Menu Bar can switch back to the whole dashboard.
- Menu bar items can each have their own label (icon, text above, text before
  or none), label text and weight, text size, number weight, colour and a
  steady width. A preview in Settings shows them as the menu bar will.
- Plan limits as a dashboard block.
- Wisp checks GitHub once a day for a new version and says so once. Turn it off
  in Settings, About.

Changed:

- New window layout, with the sidebar on a blur of the desktop and charts to the
  cards' edges. Settings is a page with its sections in the toolbar.
- Wisp follows the system's light or dark appearance on a new install.
- The Storage page only reads the disk and links to Clean Up.
- Plan limit cards put each account on one line with its plan. Codex accounts
  take T3 Code's names, and long accounts scroll on hover.

Fixed:

- Memory grew by about 200 MB a day from cached icons that were never freed.
- In dark mode the sidebar showed the light windows behind it, and switches
  could draw in light colours.
- The window buttons sometimes moved out of place.
- Changing a menu bar item's style rebuilt every item and could reorder them.

## 0.2.0, 4 November 2026

Added:

- Why Is It Slow? on Overview. It checks memory pressure, swap, CPU use per app,
  Spotlight indexing and dev servers left running, and lists what it found with
  a button to the app. Also in the menu bar dashboard, as `wisp why` and as an
  MCP tool.
- Hour and Day charts label each spike with the app that caused it.
- Storage page: a bar for the whole disk, what System Data is made of,
  developer folders (node_modules, DerivedData, Rust targets, VM disks), items
  you can move to the Trash after a confirmation, a folder drill-down, free
  space over 30 days and SSD health. The app drawer has a Storage section. Also
  `wisp storage` and an MCP tool. Scans run only while the page is open.
- Battery page with health, charge history, energy per app and what keeps the
  Mac awake. It replaces the Power page. Desktop Macs still have a Power page.
- Login & Background page listing launch agents, daemons and helpers, who made
  them, when they run and what they cost. Leftovers from deleted apps are
  flagged.
- Network in the app drawer: connections by host, listening ports and data used
  today, this week and this month. The Network page adds Most data and Hosts.

Changed:

- Plan limits come from Claude Code's status line and Codex's session logs.
  Wisp no longer reads either sign-in or contacts either company. If you had
  plan limits on, click Connect on the Coding Agents page.
- A second click on the menu bar item closes the dashboard.
- The app drawer stays open when the Apps list re-sorts.
- Every table has striped rows.

## 0.1.0, 31 October 2026

First release.
