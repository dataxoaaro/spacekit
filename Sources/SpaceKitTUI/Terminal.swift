import Darwin
import Foundation

public enum Key: Equatable, Sendable {
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, escape, backspace, tab, backTab, space
    case character(Character)
    case control(Character)
}

/// Raw-mode terminal I/O for the full-screen interface.
public final class Terminal: @unchecked Sendable {
    private var original = termios()
    private var isRaw = false
    nonisolated(unsafe) private static var active: Terminal?

    public init() {}

    public static var isInteractive: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }

    public var size: (columns: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (100, 30)
    }

    /// Enters raw mode and the alternate screen. Always pair with `restore()`.
    public func enter() {
        guard !isRaw else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cflag |= tcflag_t(CS8)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 0
            bytes[Int(VTIME)] = 1
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        Terminal.active = self
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[2J")
        for sig in [SIGTERM, SIGHUP] {
            signal(sig) { _ in
                Terminal.active?.restore()
                exit(1)
            }
        }
    }

    public func restore() {
        guard isRaw else { return }
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        isRaw = false
    }

    public func write(_ text: String) {
        var data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress! + offset, $0.count - offset) }
            if n <= 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            offset += n
        }
    }

    /// Waits up to `timeout` seconds for a key.
    public func readKey(timeout: TimeInterval) -> Key? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return Terminal.parse(Array(buffer[0..<count]))
    }

    static func parse(_ bytes: [UInt8]) -> Key? {
        guard let first = bytes.first else { return nil }
        if first == 0x1B {
            if bytes.count == 1 { return .escape }
            if bytes.count >= 3 && (bytes[1] == UInt8(ascii: "[") || bytes[1] == UInt8(ascii: "O")) {
                switch bytes[2] {
                case UInt8(ascii: "A"): return .up
                case UInt8(ascii: "B"): return .down
                case UInt8(ascii: "C"): return .right
                case UInt8(ascii: "D"): return .left
                case UInt8(ascii: "H"): return .home
                case UInt8(ascii: "F"): return .end
                case UInt8(ascii: "Z"): return .backTab
                case UInt8(ascii: "5"): return .pageUp
                case UInt8(ascii: "6"): return .pageDown
                case UInt8(ascii: "1"), UInt8(ascii: "7"): return .home
                case UInt8(ascii: "4"), UInt8(ascii: "8"): return .end
                default: return nil
                }
            }
            return .escape
        }
        switch first {
        case 13, 10: return .enter
        case 127, 8: return .backspace
        case 9: return .tab
        case 32: return .space
        case 1...26: return .control(Character(UnicodeScalar(first + 96)))
        default:
            guard let text = String(bytes: bytes, encoding: .utf8), let character = text.first else { return nil }
            return .character(character)
        }
    }
}
