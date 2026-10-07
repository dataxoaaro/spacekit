/// Tags background work so that only the result of the latest request is used. A scan that finishes after a newer
/// one started, or an analysis of a tree that has since been replaced, carries a stale tag and is dropped.
public struct RequestGeneration: Sendable, Equatable {
    public private(set) var current: UInt64 = 0

    public init() {}

    /// Starts a new request and returns its tag. Every earlier tag becomes stale.
    public mutating func next() -> UInt64 {
        current &+= 1
        return current
    }

    public func isCurrent(_ tag: UInt64) -> Bool { tag == current }
}
