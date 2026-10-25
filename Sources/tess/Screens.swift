import AppKit

/// Displays as tess sees them: global coordinates with y growing downwards (as AX uses),
/// visible frames (no menu bar or Dock), numbered left to right, then top to bottom.
enum Screens {
    struct Info {
        var id: String
        var frame: CGRect
        var isMain: Bool
    }

    static func current() -> [Info] {
        guard let main = NSScreen.screens.first else { return [] }
        return NSScreen.screens.compactMap { s -> Info? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
                  let id = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return Info(id: id, frame: flip(s.visibleFrame), isMain: s == main)
        }.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    /// Between AppKit's bottom-left origin and AX's top-left origin (an involution).
    static func flip(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
