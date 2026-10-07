# Configuration

SpaceKit reads one YAML file, shared by the app, the TUI, the CLI and the background agent:

```
~/.config/spacekit/config.yaml        (or $XDG_CONFIG_HOME/spacekit/config.yaml, or $SPACEKIT_CONFIG)
```

You can edit it two ways, and they stay in sync:

- **By hand.** Keep it in your dotfiles; `spacekit config validate` checks it; `spacekit config edit` opens it in `$EDITOR` and validates on save.
- **In the app.** *SpaceKit → Settings…* edits the same file. When the app writes it, your previous version is kept as `config.yaml.bak`. (Comments are not preserved by UI edits.)

```sh
spacekit config init        # write a commented starter config
spacekit config show        # print the effective config, defaults filled in
spacekit config path        # where config, rules and state live
```

Every key is optional. **Sizes** accept `500MB`, `30GB`, `1.5TB` (decimal, like Finder) or `512MiB` (binary). **Ages** accept `14d`, `2w`, `3mo`, `1y`, `12h`; a bare number means days. **Schedules** accept `hourly`, `daily`, `weekly`, `monthly`, `sunday 03:00`, `daily at 02:30`, or an object.

## Full reference

```yaml
version: 1

scan:
  defaultPath: /            # what Explore scans first; / is the whole startup disk, hidden folders included
  minFileSize: 1MB          # smaller files are summarised per folder ("812 smaller files"); 0 keeps every file
  boundary: container       # container | device | unrestricted (see below)
  exclude: []               # paths or globs never descended into, e.g. [~/VMs, "**/node_modules/.cache"]
  threads: 6                # scanner workers; omit for the measured default
  devRoots: [~]             # where pattern rules (node_modules, target/, .venv …) search for projects

safety:
  trash: always             # always: everything goes to the Trash · rules: regenerable caches may be deleted directly
  maxBytesPerRun: 100GB     # an automatic run never removes more than this
  protectedPaths: []        # your own never-touch list, e.g. [~/Work/client-archive]; adds to the built-in list
  allowedCommands: []       # extra tools rule commands may run, beyond the trusted list

rules:
  disabled: []              # rule ids to ignore, e.g. [cache.user-caches]
  directories:              # your own rule files (see RULES.md)
    - ~/.config/spacekit/rules

automation:
  notifications: true
  checkEvery: 1h            # how often the background agent checks for due jobs (min 5m)
  snapshot: sunday 04:00    # full storage snapshot for History; "never" to disable
  activeModelWindow: 90d    # AI models used within this window count as active

jobs:
  - id: xcode-derived-data  # optional; derived from name
    name: Xcode DerivedData
    enabled: true
    rules: [xcode.derived-data]
    paths: []               # your own folders (instead of, or in addition to, rules)
    granularity: children   # for paths: clean each entry inside (children) or the folder itself (whole)
    mode: automatic         # observe | suggest | automatic
    schedule: sunday 03:00
    when:
      sizeAbove: 30GB       # only act when the matched total exceeds this
      olderThan: 60d        # only items unused at least this long
      keepRecent: 14d       # never items used within this window
    action: trash           # trash | delete | rule (follow each rule's safety.trash)
    includeReview: false    # allow 🟡 review items in automatic runs

ui:
  visualization: sunburst   # sunburst | treemap
  colorBy: branch           # branch | category | safety | age
  mapDepth: 4               # rings / nesting levels (1–8)
```

### `scan.boundary`

| Value | Scanning `/` covers | Use when |
|---|---|---|
| `container` (default) | Every volume in the startup disk's APFS container: System, Data, swap (VM), Preboot, Update. Firmlinked folders are counted once. | You want the whole disk to add up. |
| `device` | Only the volume of the scanned path. | Scanning one volume of a multi-volume container. |
| `unrestricted` | Every mount (except virtual file systems). | Scanning a folder that has other disks mounted inside. |

Space the scan can't see (local Time Machine snapshots, purgeable space, folders blocked by privacy settings) shows up as **Hidden & Purgeable** in the category breakdown.

### Jobs and modes

| Mode | What a scheduled run does |
|---|---|
| `observe` | Notifies you when the matched total is above `when.sizeAbove`. Removes nothing. |
| `suggest` | Prepares a cleanup plan and notifies you. Approve it in the app (Automation → Waiting for your approval) or with `spacekit suggestions approve <id>`. |
| `automatic` | Cleans within the safety limits: 🟢 items only unless `includeReview`, inside the rule's locations, under `maxBytesPerRun`. Notifies you of what it did. |

Jobs only run on schedule when the background agent is installed (`spacekit agent install`, or *Install Agent* in the app). It is a per-user launchd job (`~/Library/LaunchAgents/dev.spacekit.agent.plist`) that wakes every `checkEvery`, runs due jobs, records a usage sample for History, and takes the weekly snapshot. If your Mac was asleep at the scheduled time, the job runs at the next check.

`spacekit jobs run <id>` previews what a job would do; `--yes` runs it now; `--scheduled` runs it exactly as the agent would.

## Files SpaceKit writes

| File | What |
|---|---|
| `~/.config/spacekit/config.yaml` | Your config (only written when you change settings in the app or run `config init`). |
| `~/.config/spacekit/rules/*.yaml` | Your own rules. |
| `~/Library/Application Support/SpaceKit/journal.jsonl` | Every removal (the audit log). |
| `~/Library/Application Support/SpaceKit/history.jsonl` | Usage samples and snapshots for History. |
| `~/Library/Application Support/SpaceKit/jobs-state.json` | When each job last ran and what it found. |
| `~/Library/Application Support/SpaceKit/suggestions.json` | Plans waiting for approval. |
| `~/Library/Application Support/SpaceKit/logs/agent.log` | Background agent output. |

Override the state folder with `SPACEKIT_STATE_DIR`, and the built-in rule library with `SPACEKIT_RULES_DIR`.

## Permissions

To scan everything, SpaceKit needs **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access): the app for the app, your terminal for the CLI and TUI, and `SpaceKit.app/Contents/Helpers/spacekit` (or your installed `spacekit`) for the background agent. Without it, macOS hides Mail, Messages, Safari and other apps' data; scans still work, and the hidden part is reported. `spacekit doctor` checks this.
