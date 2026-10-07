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

While developing, point SpaceKit at throwaway config and state so you don't touch your own:

```sh
export SPACEKIT_CONFIG=/tmp/sk/config.yaml SPACEKIT_STATE_DIR=/tmp/sk/state
```

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

- **Safety first.** Read [docs/SAFETY.md](docs/SAFETY.md). Anything that removes files goes through `CleanupExecutor` and `SafetyGuard`, and needs tests. Never weaken a built-in protection.
- **Performance matters.** The scanner and the rule engine run over millions of entries. Measure before and after (release builds: `swift build -c release`), and prefer incremental updates over recomputation (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **Core stays UI-free.** `SpaceKitCore` must not import AppKit or SwiftUI, so the CLI, TUI and agent share it.
- **Style.** Swift 6 language mode, strict concurrency, `swift-format` (`make lint`, `make format`). Match the surrounding code; comments explain *why*.
- **Tests** use Swift Testing (`import Testing`). File-system tests use `TempTree` and never touch real user data.

## UI screenshots (debug builds)

Debug builds of the app can be driven without Screen Recording permission, which helps when reviewing UI changes:

```sh
SPACEKIT_DEBUG_DIR=/tmp/sk/shots swift run SpaceKitApp &
printf 'scan=~/Library/Developer\n' > /tmp/sk/shots/request
printf 'section=dev\nsnapshot=dev.png\n' > /tmp/sk/shots/request      # → /tmp/sk/shots/dev.png
```

Supported keys: `section`, `visualization`, `color`, `depth`, `scan`, `focus`, `select`, `hover`, `sheet` (`onboarding`, `safety`, `job`, `cleanup`, `cleanup:<rule-id>`), `close`, `snapshot`. `confirm-cleanup` only works when `SPACEKIT_HOME` is a temporary sandbox, every item lies inside it, and the plan has no tool commands.

## Reporting bugs

Include `spacekit doctor` output, macOS version, and for scan results, `spacekit scan <path> --json`. Report safety problems privately (see [docs/SAFETY.md](docs/SAFETY.md#reporting-a-safety-problem)).
