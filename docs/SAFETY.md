# Safety Guidelines

SpaceKit removes files. That makes safety the most important property of the project, ahead of speed, features or convenience. This document is the contract: what SpaceKit will never do, how that's enforced, and what contributors must preserve.

> **The short version:** SpaceKit can never delete your disk, a volume, your home folder, your personal folders, system folders, credentials or repositories, and it never removes anything without showing you first. Automation is limited to data a rule recognises as regenerable, within a byte budget, and is journaled.

## 1. One gate for everything

Every removal, from every front end (the app, the TUI, the CLI and the background agent), passes through a single component: [`SafetyGuard`](../Sources/SpaceKitCore/Safety/SafetyGuard.swift). The `CleanupExecutor` asks the guard again **immediately before** touching each item, so a plan that was safe when it was reviewed is re-checked against the disk as it is at removal time.

The guard returns one of three decisions:

| Decision | Meaning |
|---|---|
| **allow** | May be removed. |
| **confirm** | May be removed only after a person explicitly acknowledges the shown warning. Never in automation. |
| **block** | Never removed, by anyone, in any mode. There is no override. |

## 2. Never: the whole disk, volumes and top-level folders

These are **blocked unconditionally** (`checkHardLimits`), regardless of configuration, confirmation or rules:

1. **The disk itself and every top-level folder:** `/`, `/System`, `/Users`, `/Applications`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/opt`, `/Volumes`, `/cores`, `/dev`, and any path with fewer than two components.
2. **Volume roots and mount points:** `/Volumes/<anything>`, `/System/Volumes/<anything>` (Data, Preboot, VM, Update), any path that is a mount point, and **any folder that contains a mount point**.
3. **Anything that contains a protected location.** Removing `~/Library` would remove `~/Library/Keychains`, so `~/Library` is blocked. The same ancestor rule makes the home folder, `/Users` and `/` impossible to remove.
4. **The home folder and its structure:** `~`, `~/Library`, `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Caches`, `~/Library/Developer`, `~/Library/Preferences`, `~/Library/Mobile Documents` (iCloud Drive), `~/Library/CloudStorage`, `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`, `~/Public`, `~/Applications`, `~/.Trash`, `~/.config`, `~/.cache`, `~/.local`, `~/.docker`, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`.
   *Things inside* folders like `~/Library/Caches` or `~/Downloads` can be removed (see the tiers below); the folders themselves cannot.
5. **Sealed trees, where nothing inside is ever removed:** the operating system (`/System`, `/usr/bin`, `/usr/lib`, `/usr/libexec`, `/usr/share`, `/bin`, `/sbin`, `/private/etc`, `/private/var/db`), keychains, SSH/GPG/cloud credentials (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.config/gcloud`, `~/.config/gh`), Mail, Messages, Contacts, Calendars, password managers, and Docker Desktop's VM disk (reclaim Docker space with Docker's own commands, never by deleting `Docker.raw`).
6. **Git metadata** (any path containing a `.git` component) and the **insides of library packages** such as `*.photoslibrary`, `*.musiclibrary` and keychains. Those are managed by their apps.
7. **Anything a `protected` rule describes** (databases, Docker volumes, photo libraries, credentials), and anything that contains it.
8. **Your own protected paths** from `safety.protectedPaths`, plus their contents and ancestors.
9. **Running as root.** SpaceKit refuses to remove anything when run with `sudo`.

Relative paths are refused. `~`, `..` and symlinks in parent folders are resolved before checking, so a symlink can't smuggle a protected folder in under another name. Removing a symlink removes the link, never its target.

## 3. Tiers for everything else

| What | By hand (app, TUI, CLI) | Automatic jobs |
|---|---|---|
| 🟢 Rule item, `safe` (regenerable) | allow | allow, if inside the rule's locations |
| 🟡 Rule item, `review` | confirm | only if the job sets `includeReview: true` |
| 🔴 Rule item, `protected` | block | block |
| A git repository (`.git` directly inside) | confirm | block |
| Folder containing repositories | confirm (unless a 🟢 rule claims it) | block (unless a 🟢 rule claims it) |
| Personal data (Documents, Desktop, Downloads, Pictures, Movies, Music, iCloud, app containers) without a rule | confirm | only for a folder **listed in the job**, with `olderThan` ≥ 7 days **and** moving to the Trash |
| Anything no rule recognises | confirm | block, unless the folder is listed in the job |
| A single item > 10% of the disk's used space | confirm | block above 25% |

## 4. Automation limits

- **Never silently delete.** Jobs run in one of three modes: **observe** (notify only), **suggest** (prepare a plan and wait for approval) and **automatic**. New jobs default to *suggest*, except jobs created from 🟢 rules.
- An automatic run stops at **`safety.maxBytesPerRun`** (default 100 GB). Items beyond the budget are skipped and reported.
- Automatic permanent deletion is allowed only for 🟢 regenerable items. Everything else goes to the Trash.
- Every automatic run that removes or skips something posts a notification, and every removal is written to the journal (`spacekit journal`).
- Tool commands (`docker builder prune`, `brew cleanup`, `xcrun simctl delete unavailable`) run **without a shell**, with a timeout, and only for executables on a built-in trusted list or in your `safety.allowedCommands`. Rule files can't run arbitrary programs.

## 5. Defaults that favour you

- **Preview first.** The CLI previews by default (`--yes` to act), the TUI and app always show a review screen listing every item with the guard's verdict and reasons.
- **The Trash by default.** `safety.trash: always` is the default, so everything can be put back until you empty the Trash. Set `safety.trash: rules` to let regenerable caches be deleted directly.
- **Read-only scanning.** Scans read names, sizes and dates. SpaceKit never reads file contents and sends nothing anywhere.
- **Journal.** `~/Library/Application Support/SpaceKit/journal.jsonl` records what was removed, when, how, by which rule or job, and where trashed items went.

## 6. For contributors

- **The guard is the only gate.** New features that remove anything must go through `CleanupExecutor` (which calls the guard). Never call `FileManager.removeItem`, `trashItem`, `removefile` or `rm` elsewhere.
- **Config can add protections, never remove them.** Don't add options that weaken the lists above.
- **Every guarantee has a test.** [`SafetyGuardTests`](../Tests/SpaceKitCoreTests/SafetyGuardTests.swift) covers the whole-disk, home, sealed-tree, repository, personal-folder, mount-point, symlink, root and automation rules. A change that makes any of them fail does not ship. Add a test for any new rule you introduce.
- **Rules must be honest.** If removing something costs a 20 GB download, it's `review`, even if it's "just a cache". See [RULES.md](RULES.md).
- **Debug hooks stay sandboxed.** The app's `SPACEKIT_DEBUG_DIR` automation (debug builds only) can only confirm cleanups whose every item lies inside a temporary sandbox home, and never runs tool commands.

## Reporting a safety problem

If you find a way to make SpaceKit remove something it shouldn't, please report it privately to the maintainers rather than in a public issue, with the path, the command or steps, and `spacekit doctor` output.
