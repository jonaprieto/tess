import CoreGraphics
import Foundation

/// What tess needs to know about one window, read on its app's thread.
public struct WinInfo: Equatable, Sendable {
    public var id: WindowID
    public var pid: pid_t
    public var frame: CGRect
    public var title: String
    /// `AXStandardWindow`, not minimized, not native fullscreen, app not hidden.
    public var standard: Bool
    public var fullscreenButton: Bool
    public var nativeFullscreen: Bool

    public init(id: WindowID, pid: pid_t, frame: CGRect, title: String, standard: Bool, fullscreenButton: Bool,
                nativeFullscreen: Bool) {
        (self.id, self.pid, self.frame, self.title) = (id, pid, frame, title)
        (self.standard, self.fullscreenButton, self.nativeFullscreen) = (standard, fullscreenButton, nativeFullscreen)
    }

    public enum Kind: Sendable {
        case tile, float, skip
    }

    public func kind(bundleID: String?, _ config: Config) -> Kind {
        guard standard else { return .skip }
        if let b = bundleID {
            if config.float.contains(b) { return .float }
            if config.tile.contains(b) { return .tile }
        }
        // Windows without a working fullscreen button are not meant to be big (dialogs,
        // settings, About windows): the same heuristic AeroSpace uses.
        return fullscreenButton ? .tile : .float
    }
}

extension CGRect {
    /// Within a point on every edge (AX rounds frames).
    public func isNear(_ o: CGRect) -> Bool {
        abs(minX - o.minX) <= 1 && abs(minY - o.minY) <= 1 && abs(width - o.width) <= 1 && abs(height - o.height) <= 1
    }

    /// `size` (at most 90% of the screen) centred on `screen`, on whole points.
    public static func centered(_ size: CGSize, in screen: CGRect) -> CGRect {
        let w = min(size.width, screen.width * 0.9), h = min(size.height, screen.height * 0.9)
        return CGRect(x: (screen.midX - w / 2).rounded(), y: (screen.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Less than a tenth of it shows on any of `screens` (what rescue brings back).
    public func isLost(on screens: [CGRect]) -> Bool {
        let area = width * height
        let shown = screens.map { s -> Double in
            let x = s.intersection(self)
            return x.isNull ? 0 : x.width * x.height
        }.max() ?? 0
        return area > 0 && shown < 0.1 * area
    }

    /// [x, y, width, height] in whole points, for the log.
    public var json: [Int] { [Int(minX.rounded()), Int(minY.rounded()), Int(width.rounded()), Int(height.rounded())] }
}

/// The letters windows wear: the home row first.
public let labelAlphabet = "asdhjklqwertyuiopzxcvbnm"

/// Jump mode's keys: a window's letter focuses it, shift+letter swaps it with the focused
/// window, a screen's digit focuses that screen, shift+digit moves the focused window there,
/// and each command ends with `back`. Also the key that just goes back.
public func jumpKeys(labels: [WindowID: Character], windows: [WindowID], screens: Int, back: [Command])
    -> (keys: [KeySpec: [Command]], exits: [KeySpec]) {
    var keys: [KeySpec: [Command]] = [:]
    for id in windows {
        guard let c = labels[id] else { continue }
        keys[KeySpec(key: String(c), mods: [])] = [.focusWindow(id)] + back
        keys[KeySpec(key: String(c), mods: [.shift])] = [.swapWith(id)] + back
    }
    for n in 1...min(9, max(screens, 1)) {
        keys[KeySpec(key: "\(n)", mods: [])] = [.focusMonitor(n)] + back
        keys[KeySpec(key: "\(n)", mods: [.shift])] = [.moveToMonitor(n)] + back
    }
    let exits = [KeySpec(key: "esc", mods: [])]
    for k in exits { keys[k] = back }
    return (keys, exits)
}
