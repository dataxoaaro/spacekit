# Glossary

## Rules and command trust

**Built-in rule**: a rule from SpaceKit's own rule library, which may run the tools on the built-in trusted list without configuration. _Avoid_: default rule, system rule.

**User rule**: a rule loaded from any folder other than the built-in library; its commands run only when listed in `safety.allowedCommands` and only in manual runs. _Avoid_: custom rule, third-party rule.

**Code launcher**: an executable that runs whatever code or program its arguments name (a shell, an interpreter, `env`, `xargs`, `find`, `open`); `safety.allowedCommands` can't list one. _Avoid_: interpreter (too narrow), dangerous command.

## Runs

**Manual run**: a cleanup a person reviews and starts by hand from the app, the TUI or the CLI. _Avoid_: interactive run.

**Manual job run**: a job a person runs by hand, or a suggestion they approve, in two steps (`ManualJobRun`): prepare evaluates the job and says whether it goes ahead or skips and why; complete runs the reviewed plan, records the job's last run and settles the suggestion. _Avoid_: preview job, job approval.

**Forced run**: a manual job run a person starts although the job is below its size threshold ("Run Anyway", `--force`). _Avoid_: override, threshold bypass.

**Automatic run**: a cleanup the background agent starts for an automatic job, under the automation limits and with no person confirming. _Avoid_: background run, scheduled run.

## Scans and plans

**Scan start**: the moment a scan began (`ScanTree.scanStarted`, `Analysis.scanStarted`); each cleanup item carries the scan start of the scan it came from, and loose files or Trash entries changed after it are never removed. _Avoid_: plan creation time, scan time.

## Review and execution

**Review**: a plan as a person sees it before anything is removed (`CleanupReview`): the guard's verdict on each row, the rows they untick, totals and where the items go. _Avoid_: preview (only the CLI's rendering of it), confirmation dialog.

**Warning**: a reason on a verdict that needs confirmation; it runs only if the person accepted it in the review. _Avoid_: caution, alert.

**Acknowledgement**: the person's one go-ahead for a whole review, accepting the warnings it showed or none of them. _Avoid_: confirmation (per item), approval (that's for suggestions).

**Reviewed plan**: what a review produces on acknowledgement (`ReviewedPlan`): the selected rows and the warnings shown for each; the executor's only input for a manual run. _Avoid_: confirmed plan.

**Automatic plan**: the plan `JobRunner` hands the executor for an automatic run (`AutomaticPlan`); it acknowledges nothing. _Avoid_: scheduled plan.

## Suggestions

**Suggestion**: a cleanup plan a `suggest` job prepared, waiting for a person to approve or dismiss it. _Avoid_: pending cleanup, proposal.

**Approval**: a manual job run of a suggestion: its plan, narrowed to what the job's conditions still allow, reviewed and run. _Avoid_: acceptance (that's for warnings).

**Settling a suggestion**: what an approval does with it afterwards: dismiss it when nothing eligible is left, otherwise keep it narrowed to what's left with the problems the run hit. _Avoid_: cleanup of suggestions.
