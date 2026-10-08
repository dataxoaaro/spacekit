import Foundation

/// Which programs start when a tool runs: its own file and, for a script, the `#!` interpreter the kernel starts,
/// followed through `/usr/bin/env` to the program env starts. One walk (`programWalkRefusal`) serves two checks, each
/// judging every program it reaches: the name check of an allowed tool (`launcherIdentityRefusal`) and the automatic
/// run's check that nothing on the way is the person's to change (`automaticRefusal`).
///
/// For the name check, files are not compared with each other. The Command Line Tools install one shim file under dozens
/// of names (`git`, `pip3`, `swiftc`), and Volta and mise link every tool to one shim; each picks what to run from the
/// name it was started as, so sharing a launcher's file says nothing. A copy or hard link of a launcher under another
/// name passes here: the person sees the path it was found at when they review the command.
extension CommandTrust {
    /// How many `#!` interpreters deep a script is followed before SpaceKit gives up and refuses it.
    static let interpreterDepth = 4
    /// macOS's own `env`, the only one whose options SpaceKit reads.
    static let systemEnv = "/usr/bin/env"

    /// One program the walk reaches.
    struct WalkedProgram {
        /// What asked for it: the tool's name, an interpreter's file name, or the word `env` looks up.
        let name: String
        /// Where it is: the file found for the tool, the interpreter a `#!` line names, or what `env` found.
        let path: String
        /// `/usr/bin/env`, started by a `#!/usr/bin/env` line; the walk goes on to the program it starts.
        let isEnv: Bool
    }

    /// Why the program found for `name` at `executable` runs code its arguments give it after all, or `nil`: the last
    /// component of each program's real path, and the path it was found at, must pass the name rules (a symlink called
    /// `cleanup-tool` that leads to `/bin/sh` is `sh`), and so must a script's interpreter.
    func launcherIdentityRefusal(_ name: String, at executable: String, runner: any ProcessRunner) -> String? {
        CommandTrust.programWalkRefusal(name, at: executable, locate: runner.locate) { program in
            guard !program.isEnv else { return nil }
            let real = PathUtil.realpath(program.path) ?? program.path
            for spelling in [PathUtil.lastComponent(program.path), PathUtil.lastComponent(real)] {
                if let problem = CommandTrust.allowedCommandProblem(spelling) {
                    return "'\(program.name)' at \(program.path) is \(real): \(problem)"
                }
            }
            return nil
        }
    }

    /// Why running `name`, found at `path`, starts a program `judge` refuses, or one SpaceKit can't tell; `nil` when
    /// `judge` passes every program the walk reaches. `locate` finds the program a `#!/usr/bin/env` line names, the way
    /// that run's `env` would.
    static func programWalkRefusal(
        _ name: String, at path: String, locate: (String) -> String?, judge: (WalkedProgram) -> String?
    ) -> String? {
        programRefusal(WalkedProgram(name: name, path: path, isEnv: false), locate: locate, judge: judge, depth: 0)
    }

    private static func programRefusal(
        _ program: WalkedProgram, locate: (String) -> String?, judge: (WalkedProgram) -> String?, depth: Int
    ) -> String? {
        guard depth <= interpreterDepth else {
            return "'\(program.name)' is run by scripts more than \(interpreterDepth) interpreters deep, "
                + "so SpaceKit can't tell which program runs"
        }
        if let refusal = judge(program) { return refusal }
        guard let real = PathUtil.realpath(program.path) else {
            return "Couldn't find where '\(program.name)' at \(program.path) leads, to check which program it is"
        }
        guard let header = ProgramHeader(reading: real) else {
            return "Couldn't read '\(program.name)' at \(real) to check which program it is"
        }
        switch header {
        case .compiled:
            return nil
        case .unclear(let why):
            return "'\(program.name)' at \(real) starts with #! but \(why), so SpaceKit can't tell which program runs it"
        case .script(let interpreter, let argument):
            let shown = "#!" + interpreter + (argument.map { " " + $0 } ?? "")
            let next = Interpreted(name: program.name, path: real, shown: shown)
            return interpreterRefusal(interpreter, argument, of: next, locate: locate, judge: judge, depth: depth)
        }
    }

    /// A script being followed to its interpreter: the name it was asked for by, its real path and its `#!` line as shown.
    private struct Interpreted {
        let name: String
        let path: String
        let shown: String
    }

    /// Why the interpreter a script's `#!` line names, with its one `argument`, may not run it, or `nil`.
    private static func interpreterRefusal(
        _ interpreter: String, _ argument: String?, of script: Interpreted, locate: (String) -> String?,
        judge: (WalkedProgram) -> String?, depth: Int
    ) -> String? {
        let about = "'\(script.name)' at \(script.path) is a script"
        guard interpreter.hasPrefix("/") else { return "\(about) whose interpreter SpaceKit can't tell (\(script.shown))" }
        let real = PathUtil.realpath(interpreter)
        let next: WalkedProgram
        if real == systemEnv {
            if let refusal = judge(WalkedProgram(name: "env", path: interpreter, isEnv: true)) {
                return "\(about) (\(script.shown)); \(refusal)"
            }
            guard let program = envProgram(argument) else {
                return "\(about) that env starts with options SpaceKit can't follow (\(script.shown))"
            }
            guard let found = program.hasPrefix("/") ? program : locate(program) else {
                return "\(about) for '\(program)', which isn't installed where env looks (\(script.shown))"
            }
            next = WalkedProgram(name: program, path: found, isEnv: false)
        } else if PathUtil.lastComponent(interpreter) == "env" || real.map(PathUtil.lastComponent) == "env" {
            return "\(about) for an env other than \(systemEnv), whose options SpaceKit doesn't know (\(script.shown))"
        } else {
            next = WalkedProgram(name: PathUtil.lastComponent(interpreter), path: interpreter, isEnv: false)
        }
        return programRefusal(next, locate: locate, judge: judge, depth: depth + 1).map { "\(about) (\(script.shown)); \($0)" }
    }
}

/// How macOS's `env` reads the one argument a `#!` line hands it.
extension CommandTrust {
    /// The program `env` starts given `argument`, the rest of a `#!/usr/bin/env` line, which the kernel hands it as one
    /// word; `nil` when that can't be told with certainty or names no program. env reads the word with getopt: `-i`, `-v`
    /// and `-0` take no value, `-u`, `-L` and `-U` take the rest of the word, `-S` splits the rest into more words that
    /// are read the same way, and after the options the first word that isn't `NAME=value` is the program. Without `-S`
    /// nothing is left after an option's value but the script's own path, so env would start the script again: `nil`.
    /// `-P` (another search path), quotes, escapes, `${VAR}`, and unknown or long options give `nil` too, so a script
    /// SpaceKit can't follow is refused.
    static func envProgram(_ argument: String?) -> String? {
        guard let argument else { return nil }
        guard argument.hasPrefix("-") else { return argument.contains("=") ? nil : argument }
        guard case .splits(let rest)? = envOption(argument.dropFirst()), let words = envSplit(rest), !words.isEmpty else {
            return nil
        }
        return envProgram(splitWords: words)
    }

    /// The program env starts from the words `-S` split off: options as getopt reads them, up to `--` or the first word
    /// that isn't one, then `NAME=value` words, then the program.
    private static func envProgram(splitWords: [String]) -> String? {
        var words = splitWords[...]
        while let word = words.first, word.hasPrefix("-") {
            words = words.dropFirst()
            if word == "--" { break }
            guard word != "-", let option = envOption(word.dropFirst()) else { return nil }
            switch option {
            case .noValue:
                continue
            case .takesNext:
                guard words.popFirst() != nil else { return nil }
            case .splits(let rest):
                guard let more = rest.isEmpty ? words.popFirst() : rest, let split = envSplit(more) else { return nil }
                words = (split + words)[...]
            }
        }
        return words.first { !$0.contains("=") }
    }

    private enum EnvOption {
        /// Letters that take no value.
        case noValue
        /// The last letter takes the next word as its value.
        case takesNext
        /// `-S`: what follows it in the same word (or the next word) is split into the words to read next.
        case splits(String)
    }

    /// What one cluster of `env` options (`-iv`, `-uNAME`, `-Sperl`) leaves to read, or `nil` for one SpaceKit doesn't
    /// follow: an unknown letter (a space after an option is one), or `-P`, which searches another path.
    private static func envOption(_ letters: Substring) -> EnvOption? {
        for (index, letter) in letters.enumerated() {
            let rest = String(letters.dropFirst(index + 1))
            switch letter {
            case "i", "v", "0": continue
            case "u", "L", "U": return rest.isEmpty ? .takesNext : .noValue
            case "S": return .splits(rest)
            default: return nil
            }
        }
        return .noValue
    }

    /// The words `-S` splits `text` into, at spaces and tabs; `nil` for text whose quotes, escapes or variables env would
    /// read in ways SpaceKit doesn't follow.
    private static func envSplit(_ text: String?) -> [String]? {
        guard let text, !text.contains(where: { "'\"\\$#".contains($0) }) else { return nil }
        return text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
}

/// The start of a program file, as far as which program runs it goes, read the way the macOS kernel reads it.
enum ProgramHeader: Equatable {
    /// Not a script: the system loads it itself.
    case compiled
    /// A script: the interpreter its `#!` line names and the one argument the kernel hands it, if any.
    case script(interpreter: String, argument: String?)
    /// Starts with `#!`, but not with a line the kernel runs (it then refuses the file, while `env` would hand it to
    /// `/bin/sh`): why.
    case unclear(String)

    /// The bytes the kernel reads a `#!` line from.
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
        self = ProgramHeader(line: bytes[2..<count])
    }

    /// The kernel's reading: the line ends at the first newline or `#`, which must come within `lineLimit` bytes;
    /// spaces and tabs around it go; the interpreter runs to the first space or tab, and the rest is one argument.
    private init(line bytes: ArraySlice<UInt8>) {
        let isSpace = { (byte: UInt8) in byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") }
        guard let end = bytes.firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "#") }) else {
            self = .unclear("its first line doesn't end within \(ProgramHeader.lineLimit) bytes")
            return
        }
        let line = bytes[..<end].drop(while: isSpace)
        let trimmed = line[..<(line.lastIndex { !isSpace($0) }.map { $0 + 1 } ?? line.startIndex)]
        guard !trimmed.isEmpty else {
            self = .unclear("names no interpreter")
            return
        }
        guard !trimmed.contains(0), let text = String(bytes: trimmed, encoding: .utf8) else {
            self = .unclear("its first line holds bytes that aren't text")
            return
        }
        let interpreter = text.prefix { $0 != " " && $0 != "\t" }
        let argument = text[interpreter.endIndex...].drop { $0 == " " || $0 == "\t" }
        self = .script(interpreter: String(interpreter), argument: argument.isEmpty ? nil : String(argument))
    }
}
