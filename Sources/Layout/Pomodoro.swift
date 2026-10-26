import Foundation

/// Zen's timer: a work block, then a break, repeated from `start` until Zen is turned off.
public struct Pomodoro: Equatable, Sendable {
    public var start: Date
    public var work: TimeInterval = 25 * 60
    public var rest: TimeInterval = 5 * 60

    public init(start: Date) { self.start = start }

    /// Whether `now` falls in a work block, and the seconds left in it or in the break.
    public func phase(at now: Date) -> (working: Bool, left: TimeInterval) {
        let t = max(0, now.timeIntervalSince(start)).truncatingRemainder(dividingBy: work + rest)
        return t < work ? (true, work - t) : (false, work + rest - t)
    }
}
