import Foundation
import Testing

@testable import SpaceKitCore

@Suite("AI model removal")
struct AIModelRemovalTests {
    func rule(_ tree: TempTree, builtin: Bool = true, removeCommand: [String]? = ["swift", "{name}"]) -> Rule {
        var rule = Rule(
            id: "ai.models", name: "Models", paths: [tree.path("models")], safety: SafetySpec(level: .review),
            ai: AISpec(tool: "Tool", layout: "ollama", removeCommand: removeCommand))
        rule.isBuiltin = builtin
        return rule
    }

    func model(name: String = "llama:8b", command: [String]? = ["swift", "llama:8b"], paths: [String] = []) -> AIModel {
        AIModel(name: name, kind: .model, size: 500, lastUsed: nil, paths: paths, removeCommand: command, ruleID: "ai.models")
    }

    func outcome(_ tree: TempTree, rule: Rule, plan: CleanupPlan, confirmed: Bool = true, root: Bool = false) -> CleanupOutcome? {
        sandboxExecutor(tree, rules: [rule], root: root).execute(plan, context: .manual(confirmed: confirmed), dryRun: true)
            .commands.first?.outcome
    }

    func isSkipped(_ outcome: CleanupOutcome?) -> Bool {
        if case .skipped = outcome { return true }
        return false
    }

    @Test("The rule's ai.removeCommand names each model; without one the shared blobs aren't offered")
    func inspectorUsesTemplate() throws {
        let tree = try TempTree()
        let manifest = tree.path("models/manifests/registry.ollama.ai/library/llama/8b")
        try FileManager.default.createDirectory(atPath: PathUtil.parent(manifest), withIntermediateDirectories: true)
        try Data(#"{"layers":[{"digest":"sha256:a","size":10}]}"#.utf8).write(to: URL(fileURLWithPath: manifest))
        try tree.file("models/blobs/sha256-a", bytes: 4_000)
        let item = FindingItem(path: tree.path("models"), kind: .directory, name: "models", size: 0)

        let withCommand = AIInspector.ollamaModels(finding: Finding(rule: rule(tree, removeCommand: ["ollama", "rm", "{name}"]), items: [item]))
        #expect(withCommand.first?.removeCommand == ["ollama", "rm", "llama:8b"])

        let without = try #require(AIInspector.ollamaModels(finding: Finding(rule: rule(tree, removeCommand: nil), items: [item])).first)
        #expect(without.removeCommand == nil)
        #expect(!without.isRemovable)
        #expect(CleanupPlan.removing(without) == nil)
    }

    @Test("A model with a command plans that command, which passes the executor's gates")
    func commandPlan() throws {
        let tree = try TempTree()
        let plan = try #require(CleanupPlan.removing(model()))
        #expect(plan.items.isEmpty)
        let command = try #require(plan.commands.first)
        #expect(command.arguments == ["swift", "llama:8b"])
        #expect(command.modelName == "llama:8b")
        #expect(command.estimatedBytes == 500)

        if case .wouldRemove = outcome(tree, rule: rule(tree), plan: plan) {} else { Issue.record("expected the command to run") }
        // Review rule: needs confirmation in a manual run.
        #expect(isSkipped(outcome(tree, rule: rule(tree), plan: plan, confirmed: false)))
        // Built-in trust only.
        #expect(isSkipped(outcome(tree, rule: rule(tree, builtin: false), plan: plan)))
        // Never as root.
        #expect(isSkipped(outcome(tree, rule: rule(tree), plan: plan, root: true)))
        // The rule no longer declares this command.
        #expect(isSkipped(outcome(tree, rule: rule(tree, removeCommand: ["swift", "rm", "{name}"]), plan: plan)))
        #expect(isSkipped(outcome(tree, rule: rule(tree, removeCommand: nil), plan: plan)))
    }

    @Test("Arguments that don't match the rule's template for the model are refused")
    func forgedArguments() throws {
        let tree = try TempTree()
        var plan = try #require(CleanupPlan.removing(model()))
        plan.commands[0].arguments = ["swift", "other:1b"]
        #expect(isSkipped(outcome(tree, rule: rule(tree), plan: plan)))
    }

    @Test("A model name that looks like an option is refused")
    func optionLikeName() throws {
        let tree = try TempTree()
        let plan = try #require(CleanupPlan.removing(model(name: "--version", command: ["swift", "--version"])))
        #expect(isSkipped(outcome(tree, rule: rule(tree), plan: plan)))
    }

    @Test("A model without a command plans its files and folders as they are on disk")
    func pathPlan() throws {
        let tree = try TempTree()
        let file = try tree.file("hub/a.bin", bytes: 8_000)
        try tree.directory("hub/b")
        let single = try #require(CleanupPlan.removing(model(name: "org/model", command: nil, paths: [tree.path("hub/b")])))
        #expect(single.items.map(\.kind) == [.directory])
        #expect(single.items.first?.name == "org/model")
        #expect(single.items.first?.size == 500)
        #expect(single.useTrash)

        let several = try #require(CleanupPlan.removing(model(command: nil, paths: [file, tree.path("hub/b")])))
        #expect(several.items.map(\.kind) == [.file, .directory])
        #expect(several.items.map(\.name) == ["a.bin", "b"])
        #expect(several.items.first?.size == tree.allocated("hub/a.bin"))
        #expect(CleanupPlan.removing(model(command: nil, paths: [])) == nil)
    }

    @Test("ai.removeCommand is validated like other commands and can't use {path}")
    func validation() {
        func issues(_ command: [String]) -> [RuleIssue] {
            var rule = Rule(id: "x", name: "x", paths: ["~/.tool/models"], ai: AISpec(tool: "T", layout: "ollama", removeCommand: command))
            rule.isBuiltin = true
            return RuleLibrary.issues(for: rule).filter { $0.severity == .error }
        }
        #expect(issues(["ollama", "rm", "{name}"]).isEmpty)
        #expect(!issues(["/usr/bin/ollama", "rm", "{name}"]).isEmpty)
        #expect(!issues(["ollama", "rm", "{path}"]).isEmpty)
    }
}
