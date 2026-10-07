# Architecture

SpaceKit is one Swift package with a shared core and three front ends.

```
┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐
│ SpaceKitApp  │  │ spacekit CLI │  │ SpaceKitTUI              │
│ SwiftUI      │  │ ArgumentParser│ │ raw-mode terminal UI     │
└──────┬───────┘  └──────┬───────┘  └────────────┬─────────────┘
       └─────────────────┼───────────────────────┘
                 ┌───────▼────────────────────────────────────────┐
                 │ SpaceKitCore                                   │
                 │  Scanner ─ Layout ─ Rules ─ Intelligence       │
                 │  SafetyGuard ─ Cleanup ─ Automation ─ History  │
                 └────────────────────────────────────────────────┘
                         ▲ rules/*.yaml   ▲ ~/.config/spacekit/config.yaml
```

| Target | Role |
|---|---|
| `SpaceKitCore` | Everything that isn't UI. No AppKit/SwiftUI. |
| `SpaceKitTUI` | Full-screen terminal interface (`spacekit tui`), plus ANSI helpers the CLI shares. |
| `SpaceKitCLI` → `spacekit` | Every capability as a command; also the background agent (`spacekit agent run`). |
| `SpaceKitApp` | The macOS app. Bundled by `scripts/build-app.sh` with the CLI in `Contents/Helpers`. |

## Core modules

| Folder | Contents |
|---|---|
| `Scanner/` | `Scanner` (parallel `getattrlistbulk` traversal), `DirNode` tree, `VolumeTable` (mounts, APFS containers, firmlinks). |
| `Layout/` | Squarified treemap and sunburst layouts, with hit testing. Pure geometry, shared by the app's Canvas and the TUI. |
| `Rules/` | `Rule` schema, `RuleLibrary` (loading and validation), `RuleEngine` (matching rules against a tree). |
| `Intelligence/` | `StorageAnalyzer` (targeted scans + evaluation), `CategoryBreakdown`, `AIInspector`, `RuleIndex`, incremental updates. |
| `Safety/` | `SafetyGuard`, the single gate for removals. See [SAFETY.md](SAFETY.md). |
| `Cleanup/` | `CleanupPlan`, `CleanupExecutor` (re-checks, removes, runs tool commands, journals), `Journal`. |
| `Automation/` | `Job` and `Schedule`, `JobRunner` (evaluate, observe/suggest/clean, due logic), `LaunchAgent`, state stores, notifications. |
| `Config/` | `SpaceKitConfig` (forgiving YAML decoding), `ConfigStore`, `SpaceKitContext` (wires everything from the config). |
| `History/` | Usage samples and snapshots; "this month" and "what grew". |

## The scanner

The scanner is the hot path. Its job is to turn millions of directory entries into a tree with sizes, as fast as the disk allows, without running out of memory.

- **`getattrlistbulk(2)`** returns names, types, sizes and dates for many entries per system call, about 3–5× fewer syscalls than `readdir` + `stat`, and far faster than `FileManager` enumeration.
- **Parallel work-stealing.** Worker threads share a LIFO stack of directories. Each worker keeps one child for itself and shares the rest, so the stack stays shallow and lock traffic low. Directory listing on APFS is bound by kernel locks rather than CPU. Measured on an M-series Mac (185k folders): 1 thread 5.8s, 4 threads 2.7s, 6 threads 2.7s, 24 threads 5.4s. Hence the default of about 6 threads (`scan.threads`). A 207 GB home folder with 1.8M files scans in about 13s (release build).
- **Compact memory.** Folders are objects; files are kept individually only when at least `scan.minFileSize` (1 MB by default). Smaller files are folded into per-folder totals. Swift `String`s are created only for folders and tracked files. Marker files (`package.json`, `Cargo.toml`, `.git`, …) are recognised by comparing raw bytes and stored as a 64-bit mask per folder, which is what lets pattern rules work without keeping every file name.
- **Correct sizes.** Allocated bytes (what the disk spends, not logical length); hard links counted once (pnpm stores, Time Machine); symlinks never followed; autofs triggers never opened.
- **The whole disk, once.** Scanning `/` crosses into every volume of the startup disk's APFS container (System, Data, VM swap, Preboot, Update) and skips data-volume paths that are also reachable through firmlinks (`/Users` ≡ `/System/Volumes/Data/Users`), using `/usr/share/firmlinks`. Other disks and virtual file systems are skipped. What the scan can't see is reported as *Hidden & Purgeable* (`used − scanned`).
- **Progressive results.** Folders down to `liveDepth` keep an atomic running total, and each folder is published (`isListed`, release/acquire) as soon as it's listed, so the app and TUI draw the map while the scan runs.
- **After the scan**, one non-recursive bottom-up pass computes totals, newest dates and subtree markers, and sorts children by size. The tree is then immutable, except for `applyRemoval`, which subtracts removed items from every ancestor so views update without rescanning.

### "Last used"

Modification time is used. Access times are recorded but are unreliable for folders: Spotlight and backup tools read files in the background, so an untouched folder can look used minutes ago. The exceptions are deliberate:

- For **project artifacts** (`node_modules`, `target/`), "last used" is the project's activity, meaning the newest change in the project outside the artifact, because package managers reset dates inside them.
- For **AI model weights**, reads do mean use, so the AI view uses access times.

## Rules and analysis

`RuleEngine.evaluate(tree)` produces `Finding`s:

1. **Fixed-path rules** expand `~` and globs, then look the paths up in the tree. `granularity: children` turns each entry (plus the folder's loose files) into an item.
2. **Pattern rules** walk the tree from their search roots. A folder matches by name plus a marker check: `sibling` in the parent's mask, `contains` in its own. Matching never descends into a match, into bundles, or into tool homes such as `~/Library` or `~/.cargo`.
3. **Overlaps are resolved** so no byte is counted twice. The more specific rule wins an exact path. An outer item that contains another rule's item is split into its children around it.

`StorageAnalyzer` decides what to scan. If the Explore tree already covers every location the selected rules need, it's reused. Otherwise only the needed roots are scanned, in one parallel multi-root pass. A job for DerivedData scans DerivedData, not your disk.

## Incremental updates (no full refresh)

After a cleanup, the app does **not** re-scan or re-analyse:

| What changed | What updates |
|---|---|
| Items removed from disk | `ScanTree.applyRemoval` shrinks the Explore tree (and the analysis tree, if separate) in place. Small files, which the tree only knows as a per-folder total, are removed using the size the executor measured. |
| Items moved to the Trash | `ScanTree.applyMove` re-attaches them under `~/.Trash`, so totals stay true: trashed data still uses the disk. Afterwards the Trash is re-scanned and spliced in (`ScanTree.splice`), which also picks up a Trash emptied in Finder whenever SpaceKit becomes active. |
| Findings | `Analysis.apply(_:)` drops removed items, shrinks items that lost something inside, and removes empty findings. Only the cards for touched rules change. |
| Tool commands (`brew cleanup`, `docker builder prune`) | Only those rules are re-evaluated, with a targeted scan of their own locations (`refreshFindings`). The card shows a small spinner meanwhile. |
| AI report | Rebuilt only if an AI rule was touched. Partial re-scans are merged into the existing report (`AIReport.replacingModels`), so other tools keep their models. |
| Category totals | Removed bytes are subtracted from their category, with no tree walk. |
| Disk map | Re-laid out only if the Explore tree changed (`treeRevision`). |
| Automation screen | The journal and job state are re-read (cheap). launchd is only queried when the Automation screen appears. |

Config edits work the same way. Changing a job, a safety setting or the UI options saves the YAML and updates the in-memory config. The rule library is re-read only when rule settings change.

Render-time work is cached too. Each folder's sorted item list and each path's rule lookup are memoised (outside observation) and invalidated by tree or rule changes. Disk-map layout and colors are computed off the main thread with a per-pass memo of rule lookups, so hovering and selecting only repaint.

### Proving it

`ScanTree.inconsistencies()` checks every folder's invariants (its files add up to its direct total, and its total equals direct files plus children). [`TreeConsistencyTests`](../Tests/SpaceKitCoreTests/TreeConsistencyTests.swift) runs randomized sequences of deletions, loose-file removals and moves to a Trash folder, with large and small files. After every step it compares every folder's size in the incrementally updated tree with a full rescan of the disk.

## Free space

macOS reports two numbers, and a cleanup can look like it did nothing if you show the wrong one:

| `VolumeCapacity` | Meaning |
|---|---|
| `freeNow` | Unallocated blocks right now. |
| `available` | `freeNow` plus purgeable space (local Time Machine snapshots, purgeable caches, evictable iCloud files). This is what Finder calls *Available*, and what SpaceKit shows. |
| `purgeable` | `available − freeNow`. Released automatically when space is needed. |
| `used` | `total − available` (Finder's *Used*). |

With local Time Machine snapshots on the disk, deleting files doesn't change `freeNow` at all: the snapshots still reference those blocks, so the space moves to `purgeable`, and `available` grows. SpaceKit refreshes capacity every 3 seconds and when it becomes active, explains the split in a popover, and shows the `tmutil thinlocalsnapshots` command for anyone who wants it released immediately. It never thins snapshots itself.

## Cleanup pipeline

```
Finding / selection ──► CleanupPlan ──► review (app sheet · TUI dialog · CLI preview)
                                              │ person confirms
                                              ▼
                     CleanupExecutor: for each item ─► SafetyGuard (again) ─► budget ─► Trash / removefile
                                      for each command ─► trusted? ─► run without shell ─► measure freed
                                              │
                                              ▼
                                   Journal (jsonl) + report ─► incremental UI update
```

## Automation

`spacekit agent install` writes a per-user LaunchAgent that runs `spacekit agent run` every `automation.checkEvery`. Each run:

1. records a cheap usage sample (at most every 6 hours);
2. finds due jobs (`schedule.nextRun(after: lastRun ?? firstSeen) <= now`, so missed runs catch up after sleep);
3. evaluates each job with a targeted scan, applies `when` conditions, and observes, suggests or cleans;
4. takes the weekly full snapshot for History.

## Colors

The disk map and charts use a categorical palette, a status palette (safety, always with icon and label) and a one-hue ordinal ramp (age). They're validated for color-vision deficiency and contrast in light and dark mode. See `Sources/SpaceKitApp/Theme.swift`. Don't eyeball replacements; re-validate them.
