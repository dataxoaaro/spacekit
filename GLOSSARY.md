# Glossary

## Rules and command trust

**Built-in rule**: a rule from SpaceKit's own rule library, which may run the tools on the built-in trusted list without configuration. _Avoid_: default rule, system rule.

**User rule**: a rule loaded from any folder other than the built-in library; its commands run only when listed in `safety.allowedCommands` and only in manual runs. _Avoid_: custom rule, third-party rule.

**Code launcher**: an executable that runs whatever code or program its arguments name (a shell, an interpreter, `env`, `xargs`, `find`, `open`); `safety.allowedCommands` can't list one. _Avoid_: interpreter (too narrow), dangerous command.

## Runs

**Manual run**: a cleanup a person reviews and starts by hand from the app, the TUI or the CLI. _Avoid_: interactive run.

**Automatic run**: a cleanup the background agent starts for an automatic job, under the automation limits and with no person confirming. _Avoid_: background run, scheduled run.
