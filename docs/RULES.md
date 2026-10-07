# Storage Rules

A **storage rule** is a small YAML description of one kind of data on a Mac: where it lives, what it is, how risky it is to remove, and how to clean it. Rules are SpaceKit's knowledge base. The app, the TUI, the CLI and the automation engine all read the same rules.

Built-in rules live in [`rules/`](../rules). Your own rules go in `~/.config/spacekit/rules/` (or any folder listed under `rules.directories` in your config). A rule in your folder with the same `id` as a built-in rule replaces it.

```sh
spacekit rules list                 # everything SpaceKit knows about
spacekit rules show xcode.derived-data
spacekit rules validate my-rules.yaml
spacekit rules new --name "My cache" --path ~/Library/Caches/MyTool   # scaffold
```

## File layout

A rule file is either **a single rule**, or **a list of rules** with shared defaults:

```yaml
group: Xcode                 # display group for every rule in this file
category: developer.build    # default category

rules:
  - id: xcode.derived-data
    name: Xcode DerivedData
    # …
```

```yaml
# single-rule file
name: My tool cache
path: ~/Library/Caches/com.example.tool
safety: safe
action: remove
```

## Fields

| Field | Required | Description |
|---|---|---|
| `id` | recommended | Unique, stable, dotted: `<ecosystem>.<thing>`, e.g. `node.npm-cache`. Defaults to a slug of `name`. Jobs refer to rules by id. |
| `name` | yes | Short display name: `Xcode DerivedData`. |
| `group` | | Display group (`Xcode`, `JavaScript`, `Ollama`). Defaults to the file's `group`. |
| `category` | | Dotted category. The first part drives the app's breakdown: `developer.*`, `ai.*`, `cache.*`, `system.*`, `personal.*`. |
| `description` | | One or two sentences, written for a developer: what it is, and what happens if it's removed. |
| `path` | one of `path`/`match` | Fixed location(s). String or list. `~` and globs (`*`, `?`, `[…]`) allowed. Must be at least two levels deep and never the home folder itself. |
| `match` | one of `path`/`match` | Name-based matching anywhere under search roots (see below). |
| `granularity` | | `whole` (default): the matched folder is one item. `children`: each entry inside is an item, so age rules apply per entry (per project in DerivedData). |
| `recreatedBy` | | What recreates it ("Xcode", "npm install"). Shown as *Recreated by*. |
| `safety` | | `safe`, `review` or `protected` (see below), or `{ level: safe, trash: false }`. Default `review`. |
| `policy` | | Suggested automation when someone creates a job from this rule. |
| `exclusions` | | Globs to leave alone, plus the token `active_projects` (honour `policy.keepRecent`, default 14 days). |
| `action` | | How to clean (see below). Default: nothing (report only). |
| `ai` | | Marks AI storage for the AI Development view (see below). |
| `docs` | | Link to the tool's own documentation on its storage. |
| `tags` | | Free-form labels. |

### Safety levels

| Level | Meaning | Automation |
|---|---|---|
| `safe` 🟢 | **Regenerable.** The owning tool recreates it on demand: build output, package caches, logs. | Allowed in `automatic` jobs. |
| `review` 🟡 | **Removable, but costs something**: re-download time (models, simulator runtimes), or it may be wanted (archives, backups). | Only with `includeReview: true` on the job; manual removal asks for confirmation. |
| `protected` 🔴 | **Don't touch.** Listed so SpaceKit can *show* it and *protect* it: source code, credentials, databases, Docker volumes, photo libraries. | Never. The safety guard blocks removal of these paths and anything containing them. Protected rules may not have an `action`. |

Aliases are accepted: `regenerable`/`low` → `safe`; `caution`/`medium` → `review`; `never`/`keep`/`high` → `protected`.

`safety.trash` (default `true`) says whether removal goes to the Trash. Set it to `false` only for data that is regenerated with no loss (build output, caches). Users can force the Trash for everything with `safety.trash: always` in their config, which is also the default.

### `match`: finding project artifacts anywhere

```yaml
match:
  names: [node_modules]        # folder names to match
  sibling: [package.json]      # at least one of these must exist next to the match
  contains: [pyvenv.cfg]       # at least one of these must exist inside the match
  roots: [~/Developer]         # where to search (default: the user's scan.devRoots, normally ~)
  exclude: [~/Work/vendor/**]  # extra globs never searched
```

Matching stops at the first match, so nested `node_modules` inside a matched one are part of it. SpaceKit never searches inside `~/Library`, tool homes (`~/.cargo`, `~/.npm`, `~/.vscode`, …) or bundles (`.app`, `.photoslibrary`), so an editor extension's `node_modules` is never mistaken for one of your projects. **Always use `sibling` or `contains`** when the folder name is generic (`build`, `target`, `dist`, `.venv`).

For project artifacts, *last used* is the project's activity (the newest change anywhere in the project except the artifact itself), because package managers reset file dates inside `node_modules` and friends.

### `action`

```yaml
action: remove                       # shorthand for { remove: true }

action:
  remove: true                       # remove matched items (Trash or delete per safety.trash)

action:
  command: [docker, builder, prune, --force]   # run the tool's own cleanup instead

action:
  itemCommand: [ollama, rm, "{name}"]          # once per item; {name} and {path} are substituted

action:
  manual: "Docker Desktop → Settings → Resources → Disk image size"
```

Prefer the tool's own cleanup command when it exists (Docker, simctl, Homebrew, pnpm). It knows about references and locks that deleting files doesn't.

Commands run **without a shell**. Only these executables run without extra configuration: `brew docker xcrun npm pnpm yarn bun ollama go cargo pip pip3 uv conda mamba gem pod flutter dart gradle huggingface-cli hf mise rustup orb podman colima swift deno`. Anything else must be listed in the user's `safety.allowedCommands`.

### `policy`

Defaults for jobs created from the rule:

```yaml
policy:
  type: size          # informational: size | age | schedule
  threshold: 30GB     # act when the total exceeds this
  olderThan: 60d      # only items unused this long
  keepRecent: 14d     # never items used within this window
  schedule: weekly    # hourly | daily | weekly | monthly | "sunday 03:00"
  mode: automatic     # observe | suggest | automatic
```

### `ai`

```yaml
ai:
  tool: Ollama         # name in the AI Development view
  layout: ollama       # how models are laid out on disk
```

| Layout | Meaning |
|---|---|
| `ollama` | Reads `manifests/` to size each model from its blobs, and finds unreferenced blobs. |
| `huggingface` | `hub/models--org--name` folders become `org/name` models and datasets. |
| `lmstudio` | `publisher/model` folders. |
| `children` | Each entry inside the path is one model. |
| `cache` | The whole thing is a cache (no per-model breakdown). |

## Writing a good rule

1. **Be precise about the path.** Point at the cache, not its parent. `~/Library/Caches/Homebrew`, not `~/Library/Caches`.
2. **Pick the honest safety level.** If removing it costs a 20 GB re-download, it's `review`, even if it's "just a cache".
3. **Say what happens** in `description`, for someone deciding in two seconds.
4. **Prefer tool commands** over file removal when the tool tracks what it stored.
5. **Validate:** `spacekit rules validate rules/your-file.yaml`, then try it: `spacekit dev --rule your.rule-id`.
6. Built-in rules are reviewed for accuracy on current macOS and tool versions. Include a `docs` link if the tool documents its storage.

## Overlaps

Rules may overlap (a generic `~/.cache` rule and a specific `~/.cache/huggingface` rule). SpaceKit never counts a byte twice: the more specific rule claims its folder, and the generic rule's item is split around it.
