import Foundation

/// Which program an allowed name starts. A name check sees only the name a rule wrote, so the file it was found at is
/// checked too, right before it would start: the last component of its real path must pass the same name rules (a
/// symlink called `cleanup-tool` that leads to `/bin/sh` is `sh`), and a script's `#!` interpreter must be no code
/// launcher either, followed through `/usr/bin/env` to the program it starts.
///
/// Files are not compared with each other. The Command Line Tools install one shim file under dozens of names (`git`,
/// `pip3`, `swiftc`), and Volta and mise link every tool to one shim; each picks what to run from the name it was started
/// as, so sharing a launcher's file says nothing. A copy or hard link of a launcher under another name passes here: the
/// person sees the path it was found at when they review the command.
extension CommandTrust {
    /// How many `#!` interpreters deep a script is followed before SpaceKit gives up and refuses it.
    static let interpreterDepth = 4

    /// Why the program found for `name` at `executable` runs code its arguments give it after all, or `nil`.
    func launcherIdentityRefusal(_ name: String, at executable: String, runner: any ProcessRunner) -> String? {
        CommandTrust.programRefusal(name, at: executable, runner: runner, depth: 0)
    }

    private static func programRefusal(_ name: String, at path: String, runner: any ProcessRunner, depth: Int) -> String? {
        guard depth <= interpreterDepth else {
            return "'\(name)' is run by scripts more than \(interpreterDepth) interpreters deep, so SpaceKit can't tell which program runs"
        }
        guard let real = PathUtil.realpath(path) else {
            return "Couldn't find where '\(name)' at \(path) leads, to check which program it is"
        }
        for spelling in [PathUtil.lastComponent(path), PathUtil.lastComponent(real)] {
            if let problem = allowedCommandProblem(spelling) { return "'\(name)' at \(path) is \(real): \(problem)" }
        }
        guard let header = ProgramHeader(reading: real) else { return "Couldn't read '\(name)' at \(real) to check which program it is" }
        guard case .script(let line) = header else { return nil }
        return interpreterRefusal(line, of: name, at: real, runner: runner, depth: depth)
    }

    /// Why the interpreter a script's `#!` line names (`line`, split into words) may not run it, or `nil`.
    private static func interpreterRefusal(_ line: [String], of name: String, at path: String, runner: any ProcessRunner, depth: Int)
        -> String?
    {
        let shown = "#!" + line.joined(separator: " ")
        guard let interpreter = line.first, interpreter.hasPrefix("/") else {
            return "'\(name)' at \(path) is a script whose interpreter SpaceKit can't tell (\(shown))"
        }
        let refusal: String?
        if PathUtil.realpath(interpreter).map(PathUtil.lastComponent) == "env" || PathUtil.lastComponent(interpreter) == "env" {
            guard let program = envProgram(Array(line.dropFirst())) else {
                return "'\(name)' at \(path) is a script that env starts with options SpaceKit can't follow (\(shown))"
            }
            if let problem = allowedCommandProblem(PathUtil.lastComponent(program)) {
                return "'\(name)' at \(path) is a script for \(program) (\(shown)): \(problem)"
            }
            guard let found = program.hasPrefix("/") ? program : runner.locate(program) else {
                return "'\(name)' at \(path) is a script for \(program), which isn't installed (\(shown))"
            }
            refusal = programRefusal(program, at: found, runner: runner, depth: depth + 1)
        } else {
            refusal = programRefusal(PathUtil.lastComponent(interpreter), at: interpreter, runner: runner, depth: depth + 1)
        }
        return refusal.map { "'\(name)' at \(path) is a script (\(shown)); \($0)" }
    }

    /// The program `env` starts given `arguments`, the words after `env` on a `#!` line, or `nil` when they can't be
    /// read with certainty. Options are read as macOS's `env` reads them: `-u`, `-P`, `-C`, `-L` and `-U` take a value,
    /// `-S` splits the rest into more words, `NAME=value` sets a variable. Any other option, long ones included, gives
    /// `nil`, so a script SpaceKit can't follow is refused.
    static func envProgram(_ arguments: [String]) -> String? {
        var words = arguments[...]
        var optionsEnded = false
        while let word = words.popFirst() {
            if !optionsEnded && word == "--" {
                optionsEnded = true
            } else if !optionsEnded && word.hasPrefix("-") && word != "-" {
                guard let rest = envOption(word.dropFirst()) else { return nil }
                switch rest {
                case .noValue: break
                case .takesNext: _ = words.popFirst()
                case .splits(let more): words = (more.isEmpty ? [] : [more]) + words
                }
            } else if word != "-" && !word.contains("=") {
                return word
            }
        }
        return nil
    }

    private enum EnvOption {
        /// Letters that take no value.
        case noValue
        /// The last letter takes the next word as its value.
        case takesNext
        /// `-S`: what follows it in the same word starts the words to read next.
        case splits(String)
    }

    /// What one cluster of `env` options (`-iv`, `-uNAME`, `-Sperl`) leaves to read, or `nil` for one it doesn't know.
    private static func envOption(_ letters: Substring) -> EnvOption? {
        for (index, letter) in letters.enumerated() {
            let rest = String(letters.dropFirst(index + 1))
            switch letter {
            case "i", "v", "0": continue
            case "u", "P", "C", "L", "U": return rest.isEmpty ? .takesNext : .noValue
            case "S": return .splits(rest)
            default: return nil
            }
        }
        return .noValue
    }
}

/// The start of a program file, as far as which program runs it goes.
private enum ProgramHeader {
    /// Not a script: the system loads it itself.
    case compiled
    /// A script, with the words of its `#!` line after `#!`.
    case script([String])

    /// The longest `#!` line macOS reads.
    static let lineLimit = 512

    /// `nil` when the file can't be read.
    init?(reading path: String) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: ProgramHeader.lineLimit)
        let count = read(fd, &bytes, bytes.count)
        guard count >= 0 else { return nil }
        guard count >= 2, bytes[0] == UInt8(ascii: "#"), bytes[1] == UInt8(ascii: "!") else {
            self = .compiled
            return
        }
        let line = bytes[2..<count].prefix { $0 != UInt8(ascii: "\n") }
        let words = String(decoding: line, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
        self = .script(words.map(String.init))
    }
}
