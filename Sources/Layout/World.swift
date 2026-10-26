import CoreGraphics
import Foundation

public typealias WindowID = UInt32

public enum Direction: String, Sendable, CaseIterable {
    case left, right, up, down

    var sign: Int { self == .left || self == .up ? -1 : 1 }
    var horizontal: Bool { self == .left || self == .right }
}

/// A screen axis. On a monitor in columns, width is the lanes' axis; in rows, height is.
public enum Axis: String, Sendable {
    case width, height
}

/// A shape for all of a screen's windows at once.
public enum Arrangement: String, Sendable, CaseIterable {
    /// The focused window on the left, the rest stacked on the right.
    case halves
    /// A column, or a row, for each window.
    case columns, rows
    /// Two columns, the first half of the windows stacked in the left one: four make quarters.
    case grid
}

/// A column (or a row, on a monitor in rows) holding a stack of windows.
public struct Lane: Equatable, Sendable {
    public var windows: [WindowID]
    /// Weight of each window along the stack.
    public var sizes: [Double]
    /// Weight of the lane across the monitor.
    public var size: Double
    /// The focused window fills the lane and the others sit behind it.
    public var accordion = false

    public init(_ windows: [WindowID], size: Double = 1, sizes: [Double]? = nil) {
        self.windows = windows
        self.sizes = sizes ?? Array(repeating: 1, count: windows.count)
        self.size = size
    }
}

public struct Monitor: Equatable, Sendable {
    /// Display UUID.
    public var id: String
    /// Visible frame (no menu bar or Dock), global coordinates with y growing downwards.
    public var frame: CGRect
    public var lanes: [Lane] = []
    /// Lanes are rows stacked top to bottom instead of columns left to right.
    public var rows: Bool
    public var fullscreen: WindowID?

    public init(id: String, frame: CGRect) {
        self.id = id
        self.frame = frame
        self.rows = frame.height > frame.width
    }

    /// Whether moving in `d` crosses lanes (true) or moves within a lane's stack.
    func isMajor(_ d: Direction) -> Bool { d.horizontal != rows }

    func isMajor(_ a: Axis) -> Bool { (a == .width) != rows }

    public var windows: [WindowID] { lanes.flatMap(\.windows) }
}

public struct Position: Equatable, Sendable {
    public var m: Int, l: Int, w: Int
}

public struct World: Equatable, Sendable {
    /// Ordered by monitor number: left to right, then top to bottom.
    public var monitors: [Monitor] = []
    /// Tracked but never positioned.
    public var floating: Set<WindowID> = []
    public var focused: WindowID? {
        didSet {
            guard let f = focused else { return }
            mru.removeAll { $0 == f }
            mru.insert(f, at: 0)
            guard let p = locate(f) else { return }
            activeMonitor = p.m
            // Another window taking focus ends tess fullscreen on its monitor.
            if let fs = monitors[p.m].fullscreen, fs != f { monitors[p.m].fullscreen = nil }
        }
    }
    /// The monitor commands act on; follows the focused tiled window.
    public var activeMonitor = 0
    /// Lanes of unplugged monitors, by display UUID, restored when the display comes back.
    public var parked: [String: [Lane]] = [:]
    /// Most recently focused first.
    public internal(set) var mru: [WindowID] = []

    public init(monitors: [Monitor] = []) {
        self.monitors = monitors
    }

    public func locate(_ id: WindowID) -> Position? {
        for (m, mon) in monitors.enumerated() {
            for (l, lane) in mon.lanes.enumerated() {
                if let w = lane.windows.firstIndex(of: id) { return Position(m: m, l: l, w: w) }
            }
        }
        return nil
    }

    public func contains(_ id: WindowID) -> Bool { locate(id) != nil || floating.contains(id) }

    public var tiled: [WindowID] { monitors.flatMap(\.windows) }

    var focusedPosition: Position? { focused.flatMap(locate) }

    /// The most recently focused window among `candidates`, else the first one.
    public func pick(_ candidates: [WindowID]) -> WindowID? {
        mru.first(where: candidates.contains) ?? candidates.first
    }
}
