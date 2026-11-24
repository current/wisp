# Changelog

## 0.4.0, 23 November 2026

Fixed:

- In light mode the sidebar turned grey over a dark window behind Wisp.
- Clean Up trashed the pnpm store, which pnpm 10 and later run global installs
  from, pnpm itself included. A clean now skips any folder that a command, a
  link beside it or a running program still uses, and says what uses it. A
  check that cannot finish counts as in use.
- AI usage showed the Codex CLI and T3 Code's Codex instance as two accounts
  when they share a sign-in. The T3 Code row then stopped updating while an
  unnamed "Codex" row held the real figures. Codex folders that name the same
  account are now one row, under T3 Code's name, with the newest figures.
- The usage dropdown showed at most four accounts and left out a fifth.
  It now shows up to six, and folders still waiting for figures no longer
  take a place.

Changed:

- Every menu bar item's dropdown is redrawn as compact cards on a light blur,
  with slim bars and the same charts as the window. Usage, Temperature, Memory, CPU, Network, GPU, Disk, Battery and Power
  each have one. Hovering a line shows more about it, and long account names
  scroll back and forth.
- A usage limit shows "Resets in" by default. Hover it to see how long the
  limit lasts at the current pace.
- Plan names drop "Google AI", so Antigravity shows "Ultra".
- AI usage shows Antigravity's limits: one 5-hour meter for the Gemini models
  and one for Claude and GPT-OSS. Wisp asks Antigravity's own language server on
  127.0.0.1 once a minute, while the Antigravity app or T3 Code's Antigravity
  bridge runs.
- Each account in AI usage shows when its figures were last reported, such
  as "Updated 4m ago". Hover it to see the account instead.
- Hovering a limit that says "Runs out in" or "Used up" shows when it
  resets, with the clock time.
- Limit meters change colour as they fill, from blue to amber to red. The
  5-hour session uses a lighter shade than the week, so the two bars are easy
  to tell apart.
- Plan limits can come from other machines. Add an SSH host, such as a devbox
  where T3 Code runs threads for you, under Settings, Assistants. Wisp reads the
  newest limit lines from T3 Code's logs there every 5 minutes, and the newest
  figures for each account win.
- Clean Up scans every tab at once when you open it, so each tab is ready
  when you get to it. Switching tabs no longer stops a scan.
- Codex limits come from Codex itself as well as its session logs. Wisp asks
  `codex app-server` for each account's current figures every 5 minutes and
  when the dropdown opens, so work done in the cloud or on another machine
  shows up too.

Added:

- Developer tab lists every git worktree a coding agent made (T3 Code, Claude
  Code, Codex, Cursor, Conductor) with its size and when it was last used,
  unticked, so you can see what they take up. Worktrees you made yourself show
  once nothing has touched them for the stale-project period. Trashing one runs
  `git worktree prune` so its branch can be checked out again.

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
