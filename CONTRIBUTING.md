# Contributing to SpaceKit

Thanks for helping developers get their disks back. The easiest high-impact contribution is a **storage rule**: if a tool you use leaves gigabytes somewhere, teach SpaceKit about it.

## Setup

Requirements: macOS 15+, Xcode 16+ (Swift 6).

```sh
git clone <your fork> && cd spacekit
make build          # debug build
make test           # the test suite, including the safety guarantees
make run            # the app from source
make tui            # the terminal UI on ~
swift run spacekit --help
```

`make app` builds `build/SpaceKit.app`, and `make install` puts the CLI in `~/.local/bin` (override with `PREFIX=…`).

### Running the tests

`make test` runs `swift test`. The test suite (Swift Testing) and the SwiftUI app target need a full Xcode; with only the Command Line Tools, `swift build --product spacekit` still builds the core, the TUI and the CLI. CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds everything, runs the tests, validates the rules and bundles the app on macOS 15. It is the source of truth for the app target, so a change to `Sources/SpaceKitApp` isn't verified until CI passes.

### A sandbox for manual testing

While developing, point SpaceKit at throwaway config and state so you don't touch your own:

```sh
export SPACEKIT_CONFIG=/private/tmp/sk/config.yaml SPACEKIT_STATE_DIR=/private/tmp/sk/state
```

- **`SPACEKIT_HOME` works in debug builds only.** It moves SpaceKit's idea of the home folder, and with it the default config and state locations and every home protection, to a sandbox folder. Release builds (`make app`, `make install`, `swift build -c release`) ignore it, so it can never strip the protections from your real home.
- **Write `/private/tmp`, not `/tmp`.** `/tmp` is a symlink to `/private/tmp`, and scans report the resolved path, so rule and job paths under `/tmp` don't match what a scan of that folder finds. The app's debug `confirm-cleanup` hook (below) also only accepts a sandbox home spelled `/private/tmp/…` or `/private/var/folders/…`.
- **Keep the real Trash out of it.** Moving to the Trash uses macOS's Trash, whatever the sandbox, so anything you clean with the default `safety.trash: always` lands in your own `~/.Trash`. To test removals without that, set `safety.trash: rules` in the sandbox config and give your fixture rules `safety: { level: safe, trash: false }` and `action: remove`, with paths inside the sandbox. A cleanup made only of such rules deletes directly. Paths you name on `spacekit clean` still go to the Trash unless you pass `--permanent`.

## Adding or fixing a rule

1. Find the right file in [`rules/`](rules), or add one (`rules/<area>/<tool>.yaml`).
2. Follow [docs/RULES.md](docs/RULES.md). Be precise about paths, honest about safety, and say in the description what happens if it's removed.
3. Validate and try it:
   ```sh
   swift run spacekit rules validate rules/developer/mytool.yaml
   swift run spacekit dev --rule mytool.cache --items 20
   swift run spacekit clean mytool.cache          # preview only; nothing is removed without --yes
   ```
4. In the PR, say which tool versions and macOS version you checked the paths on.

## Code

- **Safety first.** Read [docs/SAFETY.md](docs/SAFETY.md). Anything that removes files goes through `CleanupExecutor` and `SafetyGuard`, and needs tests. Never weaken a built-in protection. Text from the disk, rule files or tools that reaches a terminal goes through `TerminalText.sanitize`.
- **Performance matters.** The scanner and the rule engine run over millions of entries. Measure before and after (release builds: `swift build -c release`), and prefer incremental updates over recomputation (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **Core stays UI-free.** `SpaceKitCore` must not import AppKit or SwiftUI, so the CLI, TUI and agent share it.
- **Style.** Swift 6 language mode, strict concurrency, `swift-format` (`make lint`, `make format`). Match the surrounding code; comments explain *why*.
- **Tests** use Swift Testing (`import Testing`). File-system tests use `TempTree` and never touch real user data. Cleanup tests build their executor with `sandboxExecutor` ([`CleanupExecutionTests.swift`](Tests/SpaceKitCoreTests/CleanupExecutionTests.swift)), which puts the home, the Trash and the journal inside the `TempTree`, so nothing reaches your real Trash.

## UI screenshots (debug builds)

Debug builds of the app can be driven without Screen Recording permission, which helps when reviewing UI changes:

```sh
SPACEKIT_DEBUG_DIR=/tmp/sk/shots swift run SpaceKitApp &
printf 'scan=~/Library/Developer\n' > /tmp/sk/shots/request
printf 'section=dev\nsnapshot=dev.png\n' > /tmp/sk/shots/request      # → /tmp/sk/shots/dev.png
```

Supported keys: `section`, `visualization`, `color`, `depth`, `scan`, `focus`, `select`, `hover`, `sheet` (`onboarding`, `safety`, `job`, `cleanup`, `cleanup:<rule-id>`, `settings`), `close`, `snapshot`. `confirm-cleanup` runs the open cleanup only when `SPACEKIT_HOME` is a temporary sandbox spelled `/private/tmp/…` or `/private/var/folders/…`, every item lies inside it, and the plan has no tool commands. It never confirms warnings, so it removes only items the guard allows outright, such as items of a 🟢 rule.

## Reporting bugs

Include `spacekit doctor` output, macOS version, and for scan results, `spacekit scan <path> --json`. Report safety problems privately (see [docs/SAFETY.md](docs/SAFETY.md#reporting-a-safety-problem)).
