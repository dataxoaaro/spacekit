import Foundation
import SpaceKitCore

/// Terminal text styling with 256-color support. Respects `NO_COLOR`.
public struct Style: Sendable, Equatable {
    public var foreground: UInt8?
    public var background: UInt8?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false

    public init(
        fg: UInt8? = nil, bg: UInt8? = nil, bold: Bool = false, dim: Bool = false,
        italic: Bool = false, underline: Bool = false, inverse: Bool = false
    ) {
        self.foreground = fg
        self.background = bg
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
    }

    public static let plain = Style()
    public static let bold = Style(bold: true)
    public static let dim = Style(dim: true)

    public var sequence: String {
        var codes: [String] = []
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        if italic { codes.append("3") }
        if underline { codes.append("4") }
        if inverse { codes.append("7") }
        if let foreground { codes.append("38;5;\(foreground)") }
        if let background { codes.append("48;5;\(background)") }
        return codes.isEmpty ? "" : "\u{1B}[\(codes.joined(separator: ";"))m"
    }
}

public enum ANSI {
    public static let reset = "\u{1B}[0m"

    /// Whether to emit colors on standard output.
    public static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if let noColor = env["NO_COLOR"], !noColor.isEmpty { return false }
        if let force = env["SPACEKIT_FORCE_COLOR"], !force.isEmpty { return true }
        return isatty(STDOUT_FILENO) != 0
    }()

    public static func styled(_ text: String, _ style: Style) -> String {
        guard enabled, style != .plain else { return text }
        return style.sequence + text + reset
    }

    // Palette (xterm-256 indices), chosen to stay readable on light and dark backgrounds.
    public static let accent: UInt8 = 75
    public static let muted: UInt8 = 245
    public static let safe: UInt8 = 71
    public static let review: UInt8 = 178
    public static let protected: UInt8 = 167
    public static let branches: [UInt8] = [68, 73, 108, 179, 173, 168, 134, 110, 143, 175, 72, 137]

    public static func color(for level: SafetyLevel) -> UInt8 {
        switch level {
        case .safe: return safe
        case .review: return review
        case .protected: return protected
        }
    }

    /// Display width of a string, ignoring escape sequences and counting wide characters as 2 columns.
    public static func width(_ text: String) -> Int {
        var total = 0
        var inEscape = false
        for scalar in text.unicodeScalars {
            if inEscape {
                if scalar == "m" { inEscape = false }
                continue
            }
            if scalar == "\u{1B}" {
                inEscape = true
                continue
            }
            total += scalarWidth(scalar)
        }
        return total
    }

    static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v == 0 || (0x300...0x36F).contains(v) || v == 0x200D || (0xFE00...0xFE0F).contains(v) { return 0 }
        if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFF60).contains(v) || (0x1F300...0x1FAFF).contains(v)
            || (0x20000...0x3FFFD).contains(v) || v == 0x1F7E2 || v == 0x1F7E1 || v == 0x1F534
        {
            return 2
        }
        return 1
    }

    /// Truncates plain text to `width` columns, adding "…" when cut.
    public static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        if self.width(text) <= width { return text }
        var result = ""
        var used = 0
        for character in text {
            let w = character.unicodeScalars.reduce(0) { $0 + scalarWidth($1) }
            if used + w > width - 1 { break }
            result.append(character)
            used += w
        }
        return result + "…"
    }

    /// Truncates in the middle, which keeps both ends of a path readable.
    public static func truncateMiddle(_ text: String, to width: Int) -> String {
        guard self.width(text) > width, width > 3 else { return truncate(text, to: width) }
        let half = (width - 1) / 2
        let characters = Array(text)
        return String(characters.prefix(half)) + "…" + String(characters.suffix(width - 1 - half))
    }

    public static func pad(_ text: String, to width: Int, alignRight: Bool = false) -> String {
        let w = self.width(text)
        guard w < width else { return text }
        let space = String(repeating: " ", count: width - w)
        return alignRight ? space + text : text + space
    }

    /// A horizontal bar like `██████▌░░░░`.
    public static func bar(fraction: Double, width: Int, color: UInt8, trackColor: UInt8 = 238) -> String {
        guard width > 0 else { return "" }
        let clamped = min(max(fraction, 0), 1)
        let eighths = Int((clamped * Double(width) * 8).rounded())
        let full = eighths / 8
        let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        var filled = String(repeating: "█", count: full)
        var used = full
        if full < width, eighths % 8 > 0 {
            filled += partials[eighths % 8]
            used += 1
        }
        let track = String(repeating: "░", count: max(0, width - used))
        return styled(filled, Style(fg: color)) + styled(track, Style(fg: trackColor))
    }

    /// `▁▂▃▅▇` sparkline for a series.
    public static func sparkline(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max(), high > low else {
            return String(repeating: "▄", count: values.count)
        }
        let blocks = Array("▁▂▃▄▅▆▇█")
        return String(values.map { blocks[Int(((($0 - low) / (high - low)) * 7).rounded())] })
    }
}

extension String {
    public func styled(_ style: Style) -> String { ANSI.styled(self, style) }
    public func fg(_ color: UInt8) -> String { ANSI.styled(self, Style(fg: color)) }
    public var bold: String { ANSI.styled(self, .bold) }
    public var dim: String { ANSI.styled(self, .dim) }
}

extension SafetyLevel {
    /// Colored dot and label for terminals.
    public var badge: String {
        let symbol = self == .protected ? "⚠" : "●"
        return "\(symbol) \(title)".fg(ANSI.color(for: self))
    }
}
