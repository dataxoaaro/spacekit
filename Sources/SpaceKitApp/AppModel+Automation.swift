import AppKit
import Foundation
import SpaceKitCore

extension AppModel {
    // MARK: Automation

    var jobRunner: JobRunner { JobRunner(context: context) }

    /// Evaluates a job in the background and opens the review sheet with its plan.
    func previewJob(_ job: Job) {
        let runner = jobRunner
        Task {
            switch await self.evaluate(job, with: runner) {
            case .success(let evaluation):
                let plan = runner.plan(for: evaluation)
                if plan.isEmpty {
                    self.errorMessage = "\(job.name): \(evaluation.triggerSummary)."
                } else {
                    self.review(plan, title: "Run “\(job.name)” now") { report in
                        do {
                            try runner.record(.manual(evaluation, report: report))
                        } catch {
                            self.errorMessage = "Couldn't save the job's state: \(error.localizedDescription)"
                        }
                        self.refreshJournal()
                    }
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-evaluates the suggestion's job first, so only items that still meet its conditions are offered (a project
    /// used since it was prepared drops out). The suggestion stays if the cleanup removed nothing and had problems.
    func approve(_ suggestion: Suggestion) {
        guard let job = config.jobs.first(where: { $0.id == suggestion.jobID }) else {
            errorMessage = "The job “\(suggestion.jobName)” that prepared this cleanup no longer exists. Dismiss the suggestion."
            return
        }
        let runner = jobRunner
        Task {
            switch await self.evaluate(job, with: runner) {
            case .success(let evaluation):
                let plan = suggestion.plan.keeping(onlyEligible: evaluation.eligible).plan
                guard !plan.isEmpty else {
                    self.errorMessage = "Nothing in “\(suggestion.jobName)” needs cleaning any more: it was used or removed since."
                    return
                }
                self.review(plan, title: "Approve “\(suggestion.jobName)”") { report in
                    if report.removedAnything || !report.hasProblems {
                        self.dismiss(suggestion)
                    } else {
                        self.refreshJournal()
                    }
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
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
        guard let executable = AppModel.cliExecutable else {
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

    /// The `spacekit` CLI the agent runs: bundled in `SpaceKit.app/Contents/Helpers`, or installed on PATH.
    static var cliExecutable: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spacekit").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return Shell.which("spacekit")
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
