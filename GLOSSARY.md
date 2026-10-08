# Glossary

## Config

**Context**: one consistent reading of the config file (`SpaceKitContext`): the config, the rule library loaded for it, and the guard and executor built from both once; it never changes, a front end replaces it with a new one. _Avoid_: settings, environment.

**Config change**: one edit applied to the config file as it is on disk at that moment (`SpaceKitContext.applying`), returning a new context; refused, and never saved over the file, while the file is invalid. _Avoid_: config save, settings update.

**Config re-read**: reading the config file as it is now into a new context without changing it (`SpaceKitContext.rereadingConfig`), which the app does when it becomes active. _Avoid_: reload (that also re-reads the rule files), file watching.

## Rules and command trust

**Built-in rule**: a rule compiled into SpaceKit from the repository's `rules/` folder (`BuiltinRules.embedded`), which may run the tools on the built-in trusted list without configuration; only a debug build's `SPACEKIT_RULES_DIR` replaces them. _Avoid_: default rule, system rule, bundled rule.

**User rule**: a rule loaded from a rule folder on disk (the user rules folder or `rules.directories`); its commands run only when listed in `safety.allowedCommands` and only in manual runs. _Avoid_: custom rule, third-party rule.

**Override**: a user rule with a built-in rule's id, loaded in its place; it may only narrow the built-in rule (paths within the built-in paths, added exclusions, higher thresholds, ages or safety level, a less frequent schedule). _Avoid_: replacement rule, customisation.

**Command trust**: the module (`CommandTrust`) that decides whether a rule's tool command runs, from the rule's origin, the kind of run and the executable policy. _Avoid_: command allowlist (only part of it).

**Executable policy**: which executables may run: the built-in trusted list (built-in rules only), `safety.allowedCommands`, and the code launchers neither may grant. _Avoid_: whitelist.

**Code launcher**: an executable that runs whatever code or program its arguments or configuration name (a shell, an interpreter, `env`, `xargs`, `find`, `open`, `xcrun`, `git`, `rsync`); `safety.allowedCommands` can't list one in any spelling, and a tool whose program file is one under another name is refused when it would start. _Avoid_: interpreter (too narrow), dangerous command.

**Plain tool name**: a `safety.allowedCommands` entry made only of ASCII letters, digits, `.`, `_`, `+` and `-`, so the file system's case and Unicode folding can't turn it into another program's name. _Avoid_: safe name, ASCII name.

**Tool environment**: the cleaned environment every program SpaceKit starts runs with (`Shell.toolEnvironment`): PATH, HOME, user, locale, TMPDIR, XDG, DEVELOPER_DIR, Homebrew's settings and the variables that move a tool's own cache, minus any name that marks a credential; nothing else. _Avoid_: sanitized env.

**Process runner**: the port the executor finds and runs tools through (`ProcessRunner`); `SystemProcessRunner` starts real processes, tests use a recording runner. _Avoid_: shell (tools never run in one).

**Local Docker endpoint**: a Docker context whose endpoint is a unix socket on this Mac (Docker Desktop, OrbStack, Colima); `docker` rule commands run only against one, and `docker builder` commands only when the selected buildx builder is a `docker` or `docker-container` builder on one. _Avoid_: local daemon.

## Runs

**Manual run**: a cleanup a person reviews and starts by hand from the app, the TUI or the CLI. _Avoid_: interactive run.

**Manual job run**: a job a person runs by hand, or a suggestion they approve, in two steps (`ManualJobRun`): prepare evaluates the job and says whether it goes ahead or skips and why; complete runs the reviewed plan, records the job's last run and settles the suggestion. _Avoid_: preview job, job approval.

**Forced run**: a manual job run a person starts although the job is below its size threshold ("Run Anyway", `--force`). _Avoid_: override, threshold bypass.

**Automatic run**: a cleanup the background agent starts for an automatic job, under the automation limits and with no person confirming. _Avoid_: background run, scheduled run.

## Scans and plans

**Scan start**: the moment a scan began (`ScanTree.scanStarted`, `Analysis.scanStarted`); each cleanup item carries the scan start of the scan it came from, and loose files or Trash entries changed after it are never removed. _Avoid_: plan creation time, scan time.

**Workspace**: the Explore tree a person looks at in the app or the TUI, with its analysis (`Workspace`); the only place that changes the tree after the scan, waiting for every reader first. _Avoid_: session, model, tree store.

**Reader**: background work that reads the workspace's tree inside `Workspace.read`, such as an analysis or the map layout; changes wait until none is left. _Avoid_: lock holder.

**Change**: one in-place update of the workspace's tree and findings, a cleanup's removals or a re-synced folder, announced once to the front end (`Workspace.Change`). _Avoid_: refresh (that's the targeted re-evaluation of a few rules), update.

**Survivor**: the folder a front end shows in place of one a change took away: the nearest folder above where it was that's still in the tree (`Change.survivor(of:)`). _Avoid_: fallback, parent.

## Review and execution

**Review**: a plan as a person sees it before anything is removed (`CleanupReview`): the guard's verdict on each row, the rows they untick, totals and where the items go. _Avoid_: preview (only the CLI's rendering of it), confirmation dialog.

**Warning**: a reason on a verdict that needs confirmation; it runs only if the person accepted it in the review. _Avoid_: caution, alert.

**Acknowledgement**: the person's one go-ahead for a whole review, accepting the warnings it showed or none of them. _Avoid_: confirmation (per item), approval (that's for suggestions).

**Reviewed plan**: what a review produces on acknowledgement (`ReviewedPlan`): the selected rows, the reasons shown for each and where each item was judged; the executor's only input for a manual run. _Avoid_: confirmed plan.

**Reviewed location**: where the review judged an item: its path with the folder's symlinks resolved, and the folder and the item by device and inode (`RemovalTarget.Location`); a reviewed row runs only while the item is still there. _Avoid_: checked path.

**Changed since review**: a reviewed row skipped because its check at removal time raised a reason the review didn't show (a new warning, a larger share of the disk, a block) or the item isn't at its reviewed location; it counts as a problem. _Avoid_: stale row, unreviewed warning.

**Automatic plan**: the plan `JobRunner` hands the executor for an automatic run (`AutomaticPlan`); it acknowledges nothing. _Avoid_: scheduled plan.

## Removing

**Removal target**: one item as the guard and the removal see it, read from the disk once (`RemovalTarget`): its folder with every symlink resolved, the folder and the item pinned by device and inode, whether it is or contains a git repository, and its size. _Avoid_: checked path, checked directory.

**Remover**: the module that takes an item off its place (`Remover`): it builds the item's removal target, decides Trash or delete in one place, and moves or deletes the item only while it still matches its target. _Avoid_: deleter, safe removal (that's only its handle-level deletion, `SafeRemoval`).

**Removal**: one item a cleanup took off its place, as the report and the trees record it (`Removal`), whether deleted or moved to the Trash. _Avoid_: deletion.

## Suggestions

**Suggestion**: a cleanup plan a `suggest` job prepared, waiting for a person to approve or dismiss it. _Avoid_: pending cleanup, proposal.

**Approval**: a manual job run of a suggestion: its plan, narrowed to what the job's conditions still allow, reviewed and run. The job's size threshold doesn't hold it back: it held when the suggestion was made, and approving is the person's go-ahead. _Avoid_: acceptance (that's for warnings).

**Settling a suggestion**: what an approval does with it afterwards: dismiss it when nothing eligible is left, otherwise keep it narrowed to what's left with the problems the run hit. _Avoid_: cleanup of suggestions.
