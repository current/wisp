# Changelog

## 0.5.0, 26 November 2026

AI usage now comes straight from each agent, every screen is redrawn in one
design, scans are faster and cleaning is safer. After updating, Wisp shows what
changed in a What's New window.

Added:

- What's New: the first launch after an update shows what changed in each new
  version. It opens again from Settings, About, and from the menu bar item's
  menu.

Changed:

- AI usage asks each agent for its own figures, so it no longer depends on T3
  Code, a Claude Code status line or a running Antigravity app. Claude Code, Codex
  and the Antigravity CLI each report a signed-in account's limits wherever the
  account was used, with their own sign-in and without using tokens or keeping a
  conversation. Plan limits no longer change Claude Code's settings,
  and the SSH hosts setting is gone, since the figures already cover other
  machines.
- Claude accounts show a model's own weekly limit, such as Fable's, once it is in
  use.
- Plan limit cards on the Coding Agents page are redrawn like the dropdowns.
  The fullest limit is the large figure, with where it is heading by its reset.
  Each limit has a line with a mark for where even use would be by now. A pill
  says when an account is ahead of pace or near a limit. Limits read scope
  first, such as "Gemini · Weekly", and a card shows its age once the figures
  are 10 minutes old.
- Each account is checked every 5 minutes while its figures move and less often,
  up to every 30 minutes, while they stay the same.
- The AI usage dropdown opens with the limit closest to running out and a chart
  of where it is heading by its reset. Account lines have a pace mark.
- Projects, Containers and Login & Background lead with a total and a bar split
  by project, kind of disk use or developer, with the rows lined up below.
- Clean Up shows what can go as a bar split by kind, and each item has a size
  bar. History charts the space freed.
- The Apps page has totals for CPU, memory, power, disk and network above the
  table, and the sorted column gets a bar. The app drawer's chart draws its own
  readings until the hour fills in.
- The Neural Engine page shows today by hour and the services that use it. Sound
  has a volume chart that marks when apps played and when the microphone was in
  use. Bluetooth explains what it will show before access is given.
- The full menu bar dashboard uses the same design as the item dropdowns. Its
  blocks are cards on one plate, and CPU, GPU and Network have charts.
- VoiceOver reads the new cards, charts and tables, including what a pace mark
  or a coloured state means, and Clean Up's rows are checkboxes it can tick.
  Wisp's own buttons take keyboard focus when Keyboard Navigation is on.
- Settings uses the whole window, with each section's settings in cards. Blocks
  already on the dashboard show their colour and a check, and every block's
  description shows in full.
- Storage, Clean Up, Login & Background, Projects and the dashboard show their
  layout with grey rows while they read.
- AI usage shows all four of Antigravity's limits: 5-hour and weekly, for the
  Gemini models and for Claude and GPT-OSS. Before, the weekly limits were
  missing. Pick which ones show in Settings, Assistants, or from the usage
  dropdown's menu. With several shown, the menu bar item uses the fullest.
- Drag accounts in the usage dropdown into the order you want. The order is
  kept, and the Coding Agents page and the account list in Settings follow it.
  Reset Order in the dropdown's menu puts them back.
- In the menu bar, AI usage can show one exact limit of an account, such as
  Antigravity's Gemini weekly. The 5-hour and weekly limits can also sit in a
  row, next to the stacked look.
- Add more than one AI usage item to the menu bar, each with its own account,
  limit and look. One set to an account is labelled with its name.

Performance:

- Giving or removing Full Disk Access no longer throws away the Storage scan
  and reads the whole home folder again. Only the folders that were locked are
  read. A scan in progress keeps going, at low priority, when you leave the
  page, so coming back does not start it over.
- The Storage summary is about 4 times faster, and parts of a scan are shown
  every 2 seconds instead of twice a second.
- With only the menu bar showing, Wisp uses about half the CPU it did. The
  process pass takes about 0.6 ms instead of 1.1 ms. The battery item reads
  only the charge, and the GPU temperature is skipped until a dropdown opens.
- The Coding Agents page no longer reads every Claude log written today from
  the start each time the window opens. It reads only what was added. Usage
  figures from disk show at once, and the live checks for Claude Code, Codex
  and Antigravity run side by side. They pause while the displays sleep.
- Project, dev server, Docker and volume checks no longer run on the main
  thread.
- Charts, lists and dropdowns redraw only when what they show changes.
- Storage reads the home folder about a third faster, and folders such as
  ~/Library/Developer two and a half times faster. Refreshing a folder that has
  not changed takes a fraction of a second.
- Clean Up remembers what it measured. Scanning a tab again reads only what
  changed since: the Developer tab takes about half a second where it took 33,
  and Large Files shows its first file in a tenth of a second.

Fixed:

- Storage counted hard links and APFS clones again once it had seen many of
  them, and again on each refresh, so the home folder could add up to more than
  the disk holds. Each shared file now counts once in all.
- Clean Up no longer offers a mounted disk image, a folder git tracks, iCloud
  Drive files or a worktree git has already forgotten. The pnpm store and the
  Yarn cache, which tools run from, are marked check first. App logs are listed
  per app, so one open log no longer keeps them all.
- Clean Up checks every item again just before it goes, by the file's identity,
  and leaves it if something replaced it since the scan. It no longer moves a
  disk image that is mounted, a folder with a disk mounted inside it, a folder
  git tracks or a repository with its own history.
- Removing a worktree no longer makes git forget other worktrees that are
  missing, such as one on a disk that is not plugged in. Removing a simulator
  runtime names it exactly.
- A clean can be stopped while it runs. When a clean moves some items to the
  Trash and removes others, the result still says to empty the Trash.
- With AI plan limits turned off, Wisp no longer asks Claude Code, Codex or
  Antigravity for figures.
- Antigravity's limits come from the Antigravity app while it runs when the CLI
  does not answer.
- A process Wisp could not read at first is tried again, so it no longer shows
  0% CPU until it quits.
- Login & Background no longer offers to trash an item whose program is on a
  disk that is not plugged in.
- After an app is deleted, the notice and the Leftovers tab show what it left,
  including folders it used in its last week.
- Counting today's tokens on the Coding Agents page keeps only the part of a log
  it is reading in memory. Its peak fell from about 890 MB to 120 MB here.
- When Docker's first answer came back empty, Containers drew memory climbing
  from zero and lost the key under Disk use.
- In the Network and Disk dropdowns, "Last 4 minutes" could run under the
  reading beside it.
- The 30-day limit of Codex's free plan showed as weekly and turned amber too
  early.
- After the dashboard or the window had been open, the history kept recording
  their last network, disk and GPU readings every few seconds.
- The battery history's log file was never written back into the database and
  kept growing.

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
