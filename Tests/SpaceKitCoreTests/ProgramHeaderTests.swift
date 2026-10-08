import Foundation
import Testing

@testable import SpaceKitCore

/// A script's `#!` line read the way the macOS kernel reads it (`exec_shell_imgact`): within the first 512 bytes, the
/// interpreter up to the first space or tab, then everything up to the end of the line as one argument; the line ends
/// at a newline or a `#`, and trailing spaces and tabs go. `env` then reads that one argument with getopt.
@Suite("Program headers")
struct ProgramHeaderTests {
    func header(_ bytes: [UInt8]) throws -> ProgramHeader? {
        let tree = try TempTree()
        let path = tree.path("program")
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return ProgramHeader(reading: path)
    }

    func header(_ text: String) throws -> ProgramHeader? { try header(Array(text.utf8)) }

    @Test("The interpreter ends at the first space or tab, and the rest of the line is one argument")
    func scripts() throws {
        let table: [(String, String, String?)] = [
            ("#!/bin/sh\n", "/bin/sh", nil),
            ("#!/bin/sh -e\n", "/bin/sh", "-e"),
            ("#!  /bin/sh\t-e  -x \t\necho", "/bin/sh", "-e  -x"),
            ("#!/usr/bin/env -S perl -w\n", "/usr/bin/env", "-S perl -w"),
            ("#!/bin/sh # a comment\n", "/bin/sh", nil),
            ("#!/bin/sh -e#x\n", "/bin/sh", "-e"),
            // A carriage return is neither a space nor the end of the line: the kernel looks for `sh\r`.
            ("#!/bin/sh\r\n", "/bin/sh\r", nil),
            ("#!/bin/sh -e\r\n", "/bin/sh", "-e\r"),
        ]
        for (text, interpreter, argument) in table {
            #expect(try header(text) == .script(interpreter: interpreter, argument: argument), "\(text.debugDescription)")
        }
    }

    @Test("A #! line the kernel won't run is told apart, so the program is refused rather than guessed at")
    func unclearLines() throws {
        let longest = "#!/" + String(repeating: "a", count: 508) + "\n"
        #expect(longest.utf8.count == ProgramHeader.lineLimit)
        #expect(try header(longest) == .script(interpreter: String(longest.dropFirst(2).dropLast()), argument: nil))
        let unclear = [
            "#!/bin/sh",  // no end of line
            "#!\n", "#!   \t\n", "#!# comment\n",  // no interpreter
            "#!/" + String(repeating: "a", count: 509) + "\n",  // the end of the line is past the limit
        ]
        for text in unclear {
            let read = try header(text)
            guard case .unclear = read else {
                Issue.record("\(text.prefix(40).debugDescription) read as \(String(describing: read))")
                continue
            }
        }
        guard case .unclear = try header(Array("#!/bin/s".utf8) + [0] + Array("h\n".utf8)) else {
            Issue.record("a NUL byte in the line")
            return
        }
    }

    @Test("Files that don't start with #! are programs the system loads itself")
    func compiled() throws {
        for bytes in [[0xCF, 0xFA, 0xED, 0xFE, 0x0C], [], Array("#".utf8), Array("# !/bin/sh\n".utf8)] {
            #expect(try header(bytes) == .compiled, "\(bytes)")
        }
    }

    /// `env` gets the line's one argument: options are read from it with getopt, `-S` splits what follows it into
    /// more words, and the first word that is neither an option nor `NAME=value` is the program. Anything SpaceKit
    /// can't follow with certainty (`-P`, quotes, escapes, `${VAR}`, unknown or long options) gives `nil`, so the script
    /// is refused. So does a line that names no program: `env` would then run the script itself again.
    @Test("env's one argument is read as macOS's env reads it")
    func envArgument() {
        let table: [(String?, String?)] = [
            ("node", "node"), ("node --flag", "node --flag"), ("-S node --flag", "node"), ("-S  -i  LANG=C node", "node"),
            ("-iSruby", "ruby"), ("-S -u HOME node", "node"), ("-S -uHOME node", "node"), ("-S -- node", "node"),
            ("-S -S node", "node"), ("-S -v -0 node", "node"), ("-S\tnode", "node"),
            // getopt reads `-i node` as -i and then an unknown option ' '; env stops there.
            ("-i node", nil), ("-u HOME node", nil), ("-v node", nil),
            // Nothing left to name a program: env would start the script again.
            (nil, nil), ("LANG=C node", nil), ("-i", nil), ("-", nil), ("--", nil), ("-- node", nil), ("-S", nil),
            ("-S -i", nil), ("-S LANG=C", nil),
            // Can't be followed with certainty.
            ("-P /usr/bin node", nil), ("-S -P /usr/bin node", nil), ("--split-string=node", nil), ("-S ${HOME}/node", nil),
            ("-S 'node'", nil), ("-S \"node\"", nil), ("-S node\\ x", nil), ("-S -x node", nil),
        ]
        for (argument, program) in table {
            #expect(CommandTrust.envProgram(argument) == program, "\(argument ?? "nil")")
        }
    }
}
