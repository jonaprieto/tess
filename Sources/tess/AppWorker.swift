import AppKit
import ApplicationServices
import Layout

/// One app's AX traffic, on its own thread: AX observers need a run loop, and a frozen app
/// then only ever blocks itself. Every AX notification is a hint to re-read the app's
/// windows; the result goes to the main thread as a snapshot.
final class AppWorker {
    let app: NSRunningApplication
    var pid: pid_t { app.processIdentifier }
    /// Main thread: the app icon as a small bitmap, set shortly after the worker starts.
    var icon: NSImage?
    /// Main thread: (pid, windows, focused window).
    private let onSnapshot: (pid_t, [WinInfo], WindowID?) -> Void
    /// A window the mouse is moving (not resizing), as it moves.
    private let onDrag: (WindowID) -> Void

    // Worker thread only.
    private var runLoop: CFRunLoop!
    private var axApp: AXUIElement!
    private var observer: AXObserver?
    private var windows: [WindowID: AXUIElement] = [:]
    private var refreshScheduled = false
    /// Subrole and fullscreen button change rarely; read once per window (while it is not
    /// minimized and its app not hidden, when the subrole reads as a dialog).
    private var traits: [WindowID: (standard: Bool, button: Bool)] = [:]
    /// The last snapshot sent; an identical one is not sent again.
    private var sent: (infos: [WinInfo], focused: WindowID?)?
    /// tess's own frame writes fire moved and resized; until then they wait for one refresh.
    private var quietUntil: CFAbsoluteTime = 0

    // Frame writes waiting for the worker thread; a newer one for the same window replaces it.
    private let lock = NSLock()
    private var pendingFrames: [WindowID: CGRect] = [:]

    static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXMovedNotification, kAXResizedNotification,
    ]

    init(_ app: NSRunningApplication, onSnapshot: @escaping (pid_t, [WinInfo], WindowID?) -> Void,
         onDrag: @escaping (WindowID) -> Void) {
        self.app = app
        self.onSnapshot = onSnapshot
        self.onDrag = onDrag
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in self.run(ready) }
        thread.name = "tess.ax.\(app.processIdentifier)"
        thread.start()
        ready.wait()
    }

    private func run(_ ready: DispatchSemaphore) {
        runLoop = CFRunLoopGetCurrent()
        axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        // Keeps the run loop alive while the app refuses observers.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .infinity, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
        ready.signal()
        refresh()
        CFRunLoopRun()
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// A just-launched app may not answer yet; the next refresh tries again.
    private func ensureObserver() {
        guard observer == nil else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, name, refcon in
            Unmanaged<AppWorker>.fromOpaque(refcon!).takeUnretainedValue().notified(name as String, element)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        // Both or neither: missing window-created would leave new windows to the sweep.
        let ok = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification].allSatisfy {
            AXObserverAddNotification(obs, axApp, $0 as CFString, refcon) == .success
        }
        guard ok else { return }
        observer = obs
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(obs), .defaultMode)
        windows = [:]  // subscribe the windows again on this observer
    }

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Reading

    /// Worker thread. Moves and resizes right after tess's own write are its echo: one
    /// refresh once the write has settled covers them.
    private func notified(_ name: String, _ element: AXUIElement) {
        let now = CFAbsoluteTimeGetCurrent()
        // Moved under the mouse at the same size: dragged, not resized from an edge.
        if name == kAXMovedNotification, NSEvent.pressedMouseButtons & 1 != 0, let id = element.windowID,
           let was = sent?.infos.first(where: { $0.id == id })?.frame, let frame = element.frame,
           abs(frame.width - was.width) < 2, abs(frame.height - was.height) < 2 {
            DispatchQueue.main.async { [onDrag] in onDrag(id) }
        }
        if (name == kAXMovedNotification || name == kAXResizedNotification) && now < quietUntil {
            scheduleRefresh(after: quietUntil - now + 0.05)
        } else {
            scheduleRefresh()
        }
    }

    /// Re-read the windows soon; notifications come in bursts, one read covers them all.
    func scheduleRefresh(after delay: Double = 0.05) {
        perform { [self] in
            guard !refreshScheduled else { return }
            refreshScheduled = true
            let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { [self] _ in
                refreshScheduled = false
                refresh()
            }
            CFRunLoopAddTimer(runLoop, t, .defaultMode)
        }
    }

    /// The app came forward (a click on its window, cmd-tab): its focused window may be the
    /// one it had, which tess's focus has to hear even though nothing in the app changed.
    func activated() {
        perform { [self] in sent = nil }
        scheduleRefresh()
    }

    private func refresh() {
        // A drag may be pulling a tab out into a new window, or moving a tiled one: wait for
        // the mouse to come up.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            scheduleRefresh(after: 0.2)
            return
        }
        ensureObserver()
        let hidden = app.isHidden
        var seen: [WindowID: AXUIElement] = [:]
        var infos: [WinInfo] = []
        // An app busy past the AX timeout answers nothing: that is not every window closing.
        guard let list = axApp.elementsIfRead(kAXWindowsAttribute) else {
            scheduleRefresh(after: 1)
            return
        }
        let previous = Dictionary((sent?.infos ?? []).map { ($0.id, $0) }) { a, _ in a }
        for el in list {
            guard let id = el.windowID else { continue }
            if windows[id] == nil {
                AXUIElementSetMessagingTimeout(el, 0.25)
                if let observer {
                    for n in Self.windowNotifications { AXObserverAddNotification(observer, el, n as CFString, refcon) }
                }
            }
            seen[id] = el
            // One round trip for what changes; the traits only the first time.
            let v = el.attributes([kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXMinimizedAttribute, "AXFullScreen"])
            var origin = CGPoint.zero, size = CGSize.zero
            guard let p = v[0], CFGetTypeID(p) == AXValueGetTypeID(), AXValueGetValue(p as! AXValue, .cgPoint, &origin),
                  let z = v[1], CFGetTypeID(z) == AXValueGetTypeID(), AXValueGetValue(z as! AXValue, .cgSize, &size) else {
                // A read that failed for this window: keep what was known.
                if let known = previous[id] { infos.append(known) }
                continue
            }
            let frame = CGRect(origin: origin, size: size)
            let title = v[2] as? String ?? ""
            let minimized = v[3] as? Bool == true
            let fullscreen = v[4] as? Bool == true
            var t = traits[id]
            if t == nil {
                guard let subrole = el.string(kAXSubroleAttribute) else {
                    if let known = previous[id] { infos.append(known) }
                    continue
                }
                let read = (standard: subrole == kAXStandardWindowSubrole,
                            button: el.element(kAXFullScreenButtonAttribute)?.bool(kAXEnabledAttribute) == true)
                if !minimized && !hidden { traits[id] = read }
                t = read
            }
            infos.append(WinInfo(
                id: id, pid: pid, frame: frame, title: title,
                standard: !hidden && !fullscreen && !minimized && t!.standard,
                fullscreenButton: t!.button, nativeFullscreen: fullscreen))
        }
        if let observer {
            for (id, el) in windows where seen[id] == nil {
                for n in Self.windowNotifications { AXObserverRemoveNotification(observer, el, n as CFString) }
            }
        }
        windows = seen
        traits = traits.filter { seen[$0.key] != nil }
        let focused = axApp.element(kAXFocusedWindowAttribute)?.windowID
        if let sent, sent.infos == infos, sent.focused == focused { return }
        sent = (infos, focused)
        let pid = pid
        DispatchQueue.main.async { [onSnapshot] in onSnapshot(pid, infos, focused) }
    }

    // MARK: Tabs

    /// The tabs of windows `ids` that are not the selected one, left to right, with their
    /// frames; on the main thread. A window with fewer than two tabs has none.
    func tabs(of ids: [WindowID], _ done: @escaping ([(window: WindowID, frame: CGRect, element: AXUIElement)]) -> Void) {
        perform { [self] in
            var out: [(window: WindowID, frame: CGRect, element: AXUIElement)] = []
            for id in ids {
                guard let el = windows[id] else { continue }
                let tabs = Self.tabButtons(in: el, depth: 0)
                guard tabs.count > 1 else { continue }
                for t in tabs where t.attribute(kAXValueAttribute) as? Int != 1 {
                    if let f = t.frame { out.append((id, f, t)) }
                }
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    /// The buttons of the first tab group under `e`, without looking into pages, text or lists
    /// (a browser's page alone is thousands of elements).
    private static func tabButtons(in e: AXUIElement, depth: Int) -> [AXUIElement] {
        let role = e.string(kAXRoleAttribute) ?? ""
        if role == kAXTabGroupRole { return e.elements(kAXChildrenAttribute).filter { $0.string(kAXRoleAttribute) == kAXRadioButtonRole } }
        guard depth < 8, !["AXWebArea", kAXScrollAreaRole, kAXTableRole, kAXOutlineRole, kAXListRole, kAXTextAreaRole].contains(role)
        else { return [] }
        for k in e.elements(kAXChildrenAttribute) {
            let t = tabButtons(in: k, depth: depth + 1)
            if !t.isEmpty { return t }
        }
        return []
    }

    func press(_ element: AXUIElement) {
        perform { AXUIElementPerformAction(element, kAXPressAction as CFString) }
    }

    // MARK: Writing

    func setFrame(_ id: WindowID, _ r: CGRect) {
        lock.lock()
        pendingFrames[id] = r
        lock.unlock()
        perform { [self] in
            lock.lock()
            let r = pendingFrames.removeValue(forKey: id)
            lock.unlock()
            guard let r, let el = windows[id] else { return }
            // A snapshot goes out after the write even if it looks unchanged: the main thread
            // assumed this write landed, and has to hear if the app refused it. Refreshed here,
            // since an app that keeps its own size may not move at all and so notifies nothing.
            sent = nil
            quietUntil = CFAbsoluteTimeGetCurrent() + 0.15
            // Undocumented: with AXEnhancedUserInterface on (set by VoiceOver-aware apps),
            // frame changes animate and get lost (yabai 3fe4c77, Rectangle 285).
            let enhanced = axApp.bool("AXEnhancedUserInterface") == true
            if enhanced { axApp.set("AXEnhancedUserInterface", kCFBooleanFalse) }
            el.setFrame(r)
            if enhanced { axApp.set("AXEnhancedUserInterface", kCFBooleanTrue) }
            scheduleRefresh(after: 0.2)
        }
    }

    /// Raise first so the window is on top by the time the app comes forward.
    func focus(_ id: WindowID) {
        perform { [self] in
            guard let el = windows[id] else { return }
            el.set(kAXMainAttribute, kCFBooleanTrue)
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            axApp.set(kAXFrontmostAttribute, kCFBooleanTrue)
        }
    }

    /// The app's focused window, read fresh; `done` runs on the main thread.
    func focusedWindow(_ done: @escaping (WindowID?) -> Void) {
        perform { [self] in
            let id = axApp.element(kAXFocusedWindowAttribute)?.windowID
            DispatchQueue.main.async { done(id) }
        }
    }

    func close(_ id: WindowID) {
        perform { [self] in windows[id]?.press(kAXCloseButtonAttribute) }
    }

    func toggleNativeFullscreen(_ id: WindowID) {
        perform { [self] in
            guard let el = windows[id] else { return }
            el.set("AXFullScreen", el.bool("AXFullScreen") == true ? kCFBooleanFalse : kCFBooleanTrue)
        }
    }

    func stop() {
        perform { [self] in
            if let observer {
                CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            windows = [:]
            CFRunLoopStop(runLoop)
        }
    }
}
