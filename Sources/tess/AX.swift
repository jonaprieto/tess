import AppKit
import ApplicationServices
import Layout

/// Private, but stable for years: AeroSpace and yabai use it to get a window's CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func attribute(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }

    func bool(_ name: String) -> Bool? { attribute(name) as? Bool }
    func string(_ name: String) -> String? { attribute(name) as? String }

    func element(_ name: String) -> AXUIElement? {
        guard let v = attribute(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// nil when the read failed (a timeout), as opposed to an empty list.
    func elementsIfRead(_ name: String) -> [AXUIElement]? {
        guard let v = attribute(name), CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        return (v as! [CFTypeRef]).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    func elements(_ name: String) -> [AXUIElement] {
        guard let v = attribute(name), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [CFTypeRef]).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private func axValue(_ name: String) -> AXValue? {
        guard let v = attribute(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    var frame: CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = axValue(kAXPositionAttribute), AXValueGetValue(pv, .cgPoint, &p),
              let sv = axValue(kAXSizeAttribute), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Several attributes in one round trip; nil where the app had no value.
    func attributes(_ names: [String]) -> [CFTypeRef?] {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
                == .success, let values = out as? [CFTypeRef], values.count == names.count else {
            return names.map(attribute)
        }
        return values.map { v in
            CFGetTypeID(v) == AXValueGetTypeID() && AXValueGetType(v as! AXValue) == .axError ? nil : v
        }
    }

    var windowID: WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    /// Size, then position, then size again: some apps clamp a size that does not fit at the
    /// old position (AeroSpace issues 143 and 335).
    func setFrame(_ r: CGRect) {
        var size = r.size, origin = r.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &origin) else { return }
        set(kAXSizeAttribute, s)
        set(kAXPositionAttribute, p)
        set(kAXSizeAttribute, s)
    }

    func press(_ button: String) {
        guard let b = element(button) else { return }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
    }
}

/// What tess needs to know about one window, read on its app's thread.
struct WinInfo: Equatable {
    var id: WindowID
    var pid: pid_t
    var frame: CGRect
    var title: String
    /// `AXStandardWindow`, not minimized, not native fullscreen, app not hidden.
    var standard: Bool
    var fullscreenButton: Bool
    var nativeFullscreen: Bool
}

enum Kind {
    case tile, float, skip
}

extension WinInfo {
    func kind(bundleID: String?, _ config: Config) -> Kind {
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
