<img src="assets/icon.svg" width="64" height="64" alt="">

# SpaceKit

**Understand your Mac. Automate the cleanup.**

SpaceKit is an open-source disk space tool for developers: a native macOS app, a terminal UI and a scriptable CLI, built on one fast engine and one YAML configuration. It maps the whole disk, hidden folders included. It recognises what developer and AI tools leave behind, tells you what is actually safe to remove, and cleans it up on a schedule within strict safety limits.

- **🔭 Explore: where is my disk going?** An interactive sector map (sunburst) or treemap of the whole disk, colored by folder, kind, safety or age. Zoom into any sector; every folder SpaceKit recognises is labelled ("DerivedData · 🟢 Regenerable").
- **🧠 Dev Intelligence: what is actually safe to remove?** Xcode, SwiftPM, CocoaPods, Node, pnpm, Bun, Python, Rust, Go, Gradle, Android, Flutter, Docker, Homebrew, editors and more, sorted into 🟢 regenerable, 🟡 review and 🔴 don't-touch, each with *what it is*, *risk*, *recreated by* and *last used*.
- **🤖 AI Development.** Ollama, Hugging Face, LM Studio, PyTorch, Whisper and AI coding tools: what you actively use, what's been idle for 90+ days, and what's potentially reclaimable.
- **⏱ Automation.** Jobs that **observe**, **suggest** or **clean automatically** on a schedule ("clean DerivedData when > 30 GB, keep projects used within 14 days"), run by a lightweight per-user background agent. Never silent: you're notified, and everything is journaled.
- **📈 Storage History.** Used space over time, "+73 GB this month", and **what grew**.
- **📚 Storage Rules.** 170 community rules in plain YAML. Add your own in minutes.

## Safety

SpaceKit **cannot delete your disk**, a volume, your home folder, your personal folders, system folders, credentials or git repositories, and it never removes anything without a preview. Every removal, from every front end, goes through one guard that re-checks each item immediately before acting. Automation only touches data a rule recognises as regenerable, within a per-run byte budget. By default everything goes to the Trash. Read the full guidelines in **[docs/SAFETY.md](docs/SAFETY.md)**.

## Install

Requirements: macOS 15 or later, Xcode 16+ / Swift 6 to build.

```sh
make app            # → build/SpaceKit.app (includes the CLI and the rule library)
open build/SpaceKit.app

make install        # CLI → ~/.local/bin/spacekit, rules → ~/.local/share/spacekit/rules
spacekit doctor     # checks permissions, config, rules and the background agent
```

For complete results, give **Full Disk Access** to SpaceKit (and to your terminal for the CLI and TUI): *System Settings → Privacy & Security → Full Disk Access*. Without it, macOS hides Mail, Messages and other apps' data; SpaceKit reports that space as *Hidden*.

## Command line

```sh
spacekit tui [path]                       # full-screen terminal UI: Explore · Dev · AI · Automation · History
spacekit scan ~ --depth 2                 # largest folders, labelled by rule
spacekit disk --breakdown                 # whole disk by category (Developer, Applications, …)
spacekit dev                              # Dev Intelligence report
spacekit dev --rule xcode.derived-data    # one rule in detail
spacekit ai                               # local AI storage, active vs idle
spacekit clean xcode.derived-data --keep-recent 14d    # preview; add --yes to clean
spacekit clean --safety safe              # preview every regenerable item
spacekit jobs add --rule node.node-modules --older-than 60d --mode suggest
spacekit agent install                    # run jobs on schedule
spacekit suggestions                      # cleanups waiting for approval
spacekit history                          # usage over time and what grew
spacekit journal                          # everything SpaceKit removed
spacekit trash [--empty]                  # what the Trash still holds, and empty it
spacekit rules list | show <id> | validate | new
spacekit config init | show | edit | validate
```

Most commands take `--json` for scripting. Cleaning always previews first unless you pass `--yes`.

## Configuration

One YAML file, `~/.config/spacekit/config.yaml`, shared by the app, TUI, CLI and agent. Edit it by hand, keep it in your dotfiles, or use the app's Settings window; both write the same file. `spacekit config init` writes a commented starter:

```yaml
safety:
  trash: always             # everything goes to the Trash first
  maxBytesPerRun: 100GB     # automatic runs never remove more than this
  protectedPaths: [~/Work/client-archive]

jobs:
  - name: Xcode DerivedData
    rules: [xcode.derived-data]
    mode: automatic         # observe | suggest | automatic
    schedule: sunday 03:00
    when:
      sizeAbove: 30GB
      keepRecent: 14d
```

Full reference: **[docs/CONFIGURATION.md](docs/CONFIGURATION.md)**.

## Storage rules

A rule is a few lines of YAML describing one kind of data:

```yaml
name: Xcode DerivedData
category: developer.build
path:
  - ~/Library/Developer/Xcode/DerivedData
granularity: children       # one item per project
policy:
  type: size
  threshold: 30GB
safety:
  level: safe
  trash: true
exclusions:
  - active_projects
action:
  remove: true
```

The built-in library lives in [`rules/`](rules). Put your own in `~/.config/spacekit/rules/`. Schema and guidelines: **[docs/RULES.md](docs/RULES.md)**. New rules are the most valuable contribution. See **[CONTRIBUTING.md](CONTRIBUTING.md)**.

## How it's built

A Swift package with one UI-free core (`SpaceKitCore`) and three front ends: the SwiftUI app, the terminal UI and the ArgumentParser CLI. The scanner uses `getattrlistbulk` with a tuned pool of worker threads. It counts hard links once, understands APFS containers and firmlinks so the whole disk adds up exactly once, and keeps memory compact by tracking only files large enough to matter. After a cleanup, views update incrementally rather than re-scanning. Details: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

```sh
make test     # unit tests, including every safety guarantee
make lint     # swift-format
```

## License

[MIT](LICENSE)
