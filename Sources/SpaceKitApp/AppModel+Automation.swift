import AppKit
import Foundation
import SpaceKitCore

extension AppModel {
    // MARK: Automation

    var jobRunner: JobRunner { JobRunner(context: context) }

    /// Evaluates a job in the background and opens the review sheet with its plan. A job whose conditions aren't
    /// met doesn't run, as in the CLI and the TUI: the check is recorded and its result shown.
    func previewJob(_ job: Job) {
        let runner = jobRunner
        Task {
            switch await self.prepareRun(of: job.id, { try ManualJobRun.prepare(job, runner: runner) }) {
            case .success(let run): self.review(run, title: "Run “\(job.name)” now")
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Evaluates the suggestion's job again first, so only items that still meet its conditions are offered (a project
    /// used since it was prepared drops out). After the run the suggestion goes, or stays with what's left.
    func approve(_ suggestion: Suggestion) {
        let runner = jobRunner
        Task {
            switch await self.prepareRun(of: suggestion.jobID, { try ManualJobRun.prepare(suggestion, runner: runner) }) {
            case .success(let run): self.review(run, title: "Approve “\(suggestion.jobName)”")
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Opens the review of a run that goes ahead. One that would skip says why, and asks about running anyway when
    /// only the job's threshold holds it back.
    func review(_ run: ManualJobRun, title: String) {
        if let plan = run.plan {
            review(plan, title: title, job: run)
        } else if run.canForce {
            skippedRun = SkippedRun(run: run, title: title)
        } else {
            errorMessage = "\(run.evaluation.job.name): \(run.skipReason ?? "")."
        }
    }

    func runAnyway(_ skipped: SkippedRun) {
        skippedRun = nil
        review(skipped.run.forced(), title: skipped.title)
    }

    /// After a job run by hand: bookkeeping that couldn't be saved, then the job's new state and suggestions.
    func finishJobRun(_ outcome: ManualJobRun.Outcome) {
        if !outcome.saveErrors.isEmpty { errorMessage = outcome.saveErrors.joined(separator: "\n") }
        refreshJournal()
    }

    func dismiss(_ suggestion: Suggestion) {
        do {
            try context.suggestions.remove(suggestion.id)
        } catch {
            errorMessage = "Couldn't remove the suggestion: \(error.localizedDescription)"
        }
        refreshJournal()
    }

    func installAgent() {
        guard let executable = LaunchAgent.spacekitExecutable() else {
            errorMessage =
                "Couldn't find the spacekit command-line tool. Build it with `make install`, or use the app bundle from `make app`."
            return
        }
        do {
            try LaunchAgent(paths: context.paths).install(executable: executable, interval: context.config.automation.checkEvery.seconds)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshAutomation()
    }

    func uninstallAgent() {
        do {
            try LaunchAgent(paths: context.paths).uninstall()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshAutomation()
    }

    /// Saves a job: in place of the job `id` when editing, otherwise as a new job whose id doesn't clash with another.
    func saveJob(_ job: Job, replacing id: String? = nil) {
        updateConfig { $0.upsertJob(job, replacing: id) }
    }

    func deleteJob(_ job: Job) {
        updateConfig { $0.jobs.removeAll { $0.id == job.id } }
    }
}

/// A job being created or edited in the job editor.
struct JobDraft: Identifiable {
    let id = UUID()
    var job: Job
    /// The id of the job being edited, or nil for a new job.
    var originalID: String?
}

extension JobDraft {
    /// A new job for folders chosen in Explore.
    init(paths: [String]) {
        let name = paths.count == 1 ? "Clean \(PathUtil.lastComponent(paths[0]))" : "Clean \(paths.count) folders"
        self.init(
            job: Job(
                id: Rule.slug(name), name: name, paths: paths.map { PathUtil.abbreviate($0) }, mode: .suggest,
                schedule: .weekly, when: Job.Conditions(olderThan: .days(30))))
    }

    /// A new job from a rule's suggested policy.
    init(rule: Rule) {
        self.init(job: Job.suggested(for: rule))
    }
}
