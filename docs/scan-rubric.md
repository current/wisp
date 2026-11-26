# Scan rubric

Wisp reads the disk in two places: the Storage page's index of the home folder
(`StorageIndex`, `FolderScanner`) and Clean Up's scanners (`Sources/WispCore/Cleaning`).
This rubric scores each scanner the way `ui-rubric.md` scores a screen, so a slow or
risky one is found and measured before a release.

## Measuring

Time every scanner on this Mac with the disk cache warm (the second of two runs in a
row) and, where it can be arranged, cold (the first run after a reboot or after the
folders were last read hours ago). Report wall time, CPU time, peak memory and the
number of entries read. A change is measured against the old code in the same
conditions, old and new runs alternating, at least three of each, with the median
reported. A benchmark only reads. It doesn't move or delete anything outside a temporary folder.

## Criteria

There are seven criteria. Each scores 0 to 3, and a criterion that cannot apply is
marked n/a. The score is the points over the points possible, out of 10.

| | Criterion | 3 means |
| --- | --- | --- |
| **T** | Time | The result arrives about as fast as the fastest method on macOS allows for what it must read. First results show within a second. A full scan of the home folder takes no longer than the kernel needs to list it. |
| **K** | Cost | CPU, memory and disk reads stay in proportion. Each file is read once, one walk serves every scanner that needs the same folders, and memory grows with what is shown. A scan in the background runs at low priority. |
| **I** | Incremental | A second scan reads only what changed since the first (file system events, saved results, sizes from the Storage index). Opening a tab again shows the last result at once. |
| **A** | Accuracy | Sizes are allocated bytes, as Finder and `du` count them. Hard links and clones are counted once. Items are counted once each, and the screen says which folders could not be read. |
| **S** | Safety | For anything that can be removed, only safe items are offered and items in use are left alone. Links stay inside the folder. Each removal goes to the Trash or says plainly that it cannot be undone, and the item is checked again just before it goes. A read-only scan doesn't write, stays inside its folders and skips network and removable volumes. |
| **R** | Responsive | Progress shows while it runs and results appear as they are found. Stop takes effect within a fraction of a second, and the app keeps up with input meanwhile. |
| **P** | Permissions | Folders it cannot read without Full Disk Access are named, the rest still works, and granting access reads only what was locked. |

A scanner is ready at 9 or above, with a 3 under Safety for anything that removes.

## Scores

Scored on 26 November 2026 on a Mac under heavy load throughout (load average 15 to
over 100), so times are medians of runs taken back to back. Warm means the second scan,
with the cache from the first.

| Scanner | Before | After | Main change |
| --- | --- | --- | --- |
| Storage index | 7.1 | 9.5 | Threads hand work to each other, a refresh reads only what changed, links and clones are shared, not counted again |
| App storage | 7.2 | 9.4 | Each byte read once, the bundle on several threads |
| Volume reader | 9.2 | 9.2 | Only the startup disk's own system volumes |
| System junk | 6.2 | 9.5 | A row per app's logs, kept between scans |
| Time Machine snapshots | 9.2 | 9.2 | Unchanged |
| Developer caches | 4.8 | 8.6 | Warm scan 0.5 s against 33 s; pnpm and Yarn caches check first |
| Projects | 4.8 | 8.6 | Each project's walk remembered; git-tracked folders left out |
| Large Files | 4.3 | 8.6 | First row in 0.14 s against 4.2 s; iCloud Drive and mounted images left out |
| App caches | 4.8 | 8.1 | Parallel sizer; folders it could not read are named |
| Worktrees | 3.3 | 8.1 | CPU down 2.4 times; rows as they are found; forgotten worktrees not offered |
| Uninstall sizes | 4.0 | 8.0 | 2.3 times faster, and 0.3 s once sizes are known |
| Installers | 5.7 | 7.6 | Mounted disk images left out |
| Leftovers | 5.7 | 7.6 | Apps on an unplugged disk count as installed |
| Simulators | 7.1 | 7.1 | Bound by `simctl` |

Removal paths, scored on Safety, Accuracy and Responsive:

| Path | Before | After |
| --- | --- | --- |
| Trash cleans | 1, 1, 1 | 3, 2, 3 |
| Uninstall to the Trash | 1, 1, 1 | 3, 2, 2 |
| Uninstall with Homebrew | 1, 2, 2 | 3, 3, 2 |
| Simulators and runtimes | 1, 2, 3 | 3, 3, 3 |
| Worktrees | 1, 1, 2 | 3, 1, 2 |
| `wisp clean --apply` | 1, 1, 1 | 3, 2, 2 |

Every path that removes now checks each item again by identity just before it goes.
The Stop button during a clean gives Trash cleans their 3 under Responsive.

What keeps the scanners below 9 is the first scan with nothing cached: listing the
folders is the kernel's work, and on this Mac Developer and Large Files read 1.5 to 1.6
million entries each. Sharing the Storage index's sizes with Clean Up would remove most
of that and is the next thing to try.
