/// The part of a list a screen shows, moved as little as possible to keep the selected row in view.
///
/// Every result is a valid range of the list for any input, including a screen with no room for a single
/// row, an empty list and a selection past the end.
public struct ScrollWindow: Equatable, Sendable {
    public private(set) var offset: Int

    public init(offset: Int = 0) { self.offset = max(0, offset) }

    /// Scrolls so `selection` is visible in `visible` rows of a `count`-row list and returns the rows to draw.
    public mutating func follow(selection: Int, visible: Int, count: Int) -> Range<Int> {
        let count = max(0, count)
        let visible = max(0, visible)
        guard count > 0, visible > 0 else {
            offset = 0
            return 0..<0
        }
        let selection = min(max(selection, 0), count - 1)
        var start = offset
        if selection < start { start = selection }
        if selection >= start + visible { start = selection - visible + 1 }
        offset = min(max(start, 0), max(0, count - visible))
        return offset..<min(count, offset + visible)
    }
}

/// A scrolling view of read-only lines that remembers whether its last line has been on screen, so a
/// confirmation can wait until everything it covers has been shown.
public struct Pager: Equatable, Sendable {
    public let lineCount: Int
    public private(set) var offset = 0
    /// True once the last line has been drawn (or there were no lines).
    public private(set) var hasShownEnd = false

    public init(lineCount: Int) { self.lineCount = max(0, lineCount) }

    /// Moves by `delta` lines when `visible` lines fit, without scrolling past either end.
    public mutating func scroll(by delta: Int, visible: Int) {
        offset = Pager.clamp(offset + delta, lineCount: lineCount, visible: visible)
    }

    /// The lines to draw in `visible` rows. Call it with what is actually drawn: it records whether the end
    /// was shown.
    public mutating func display(visible: Int) -> Range<Int> {
        guard visible > 0 else { return offset..<offset }
        offset = Pager.clamp(offset, lineCount: lineCount, visible: visible)
        let range = offset..<min(lineCount, offset + visible)
        if range.upperBound == lineCount { hasShownEnd = true }
        return range
    }

    private static func clamp(_ offset: Int, lineCount: Int, visible: Int) -> Int {
        min(max(offset, 0), max(0, lineCount - max(1, visible)))
    }
}
