import AppKit
import ApplicationServices
import Layout

/// One app's AX traffic, on its own thread: AX observers need a run loop, and a frozen app
/// then only ever blocks itself. Every AX notification is a hint to re-read the app's
/// windows; the result goes to the main thread as a snapshot.
final class AppWorker {
    let app: NSRunningApplication
    var pid: pid_t { app.processIdentifier }
    /// Main thread: (pid, windows, focused window).
    private let onSnapshot: (pid_t, [WinInfo], WindowID?) -> Void

    // Worker thread only.
    private var runLoop: CFRunLoop!
    private var axApp: AXUIElement!
    private var observer: AXObserver?
    private var windows: [WindowID: AXUIElement] = [:]
    private var refreshScheduled = false

    // Frame writes waiting for the worker thread; a newer one for the same window replaces it.
    private let lock = NSLock()
    private var pendingFrames: [WindowID: CGRect] = [:]

    static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXMovedNotification, kAXResizedNotification,
    ]

    init(_ app: NSRunningApplication, onSnapshot: @escaping (pid_t, [WinInfo], WindowID?) -> Void) {
        self.app = app
        self.onSnapshot = onSnapshot
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
        let callback: AXObserverCallback = { _, _, _, refcon in
            Unmanaged<AppWorker>.fromOpaque(refcon!).takeUnretainedValue().scheduleRefresh()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        var ok = false
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            ok = AXObserverAddNotification(obs, axApp, n as CFString, refcon) == .success || ok
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

    private func refresh() {
        // A drag may be pulling a tab out into a new window, or moving a tiled one: wait for
        // the mouse to come up (AeroSpace issue 1001).
        if NSEvent.pressedMouseButtons & 1 != 0 {
            scheduleRefresh(after: 0.2)
            return
        }
        ensureObserver()
        let hidden = app.isHidden
        var seen: [WindowID: AXUIElement] = [:]
        var infos: [WinInfo] = []
        for el in axApp.elements(kAXWindowsAttribute) {
            guard let id = el.windowID, let frame = el.frame else { continue }
            if windows[id] == nil {
                AXUIElementSetMessagingTimeout(el, 0.25)
                if let observer {
                    for n in Self.windowNotifications { AXObserverAddNotification(observer, el, n as CFString, refcon) }
                }
            }
            seen[id] = el
            let fullscreen = el.bool("AXFullScreen") == true
            let button = el.element(kAXFullScreenButtonAttribute)
            infos.append(WinInfo(
                id: id, pid: pid, frame: frame, title: el.string(kAXTitleAttribute) ?? "",
                standard: !hidden && !fullscreen && el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
                    && el.bool(kAXMinimizedAttribute) != true,
                fullscreenButton: button?.bool(kAXEnabledAttribute) == true,
                nativeFullscreen: fullscreen))
        }
        if let observer {
            for (id, el) in windows where seen[id] == nil {
                for n in Self.windowNotifications { AXObserverRemoveNotification(observer, el, n as CFString) }
            }
        }
        windows = seen
        let focused = axApp.element(kAXFocusedWindowAttribute)?.windowID
        let pid = pid
        DispatchQueue.main.async { [onSnapshot] in onSnapshot(pid, infos, focused) }
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
            // Undocumented: with AXEnhancedUserInterface on (set by VoiceOver-aware apps),
            // frame changes animate and get lost (yabai 3fe4c77, Rectangle 285).
            let enhanced = axApp.bool("AXEnhancedUserInterface") == true
            if enhanced { axApp.set("AXEnhancedUserInterface", kCFBooleanFalse) }
            el.setFrame(r)
            if enhanced { axApp.set("AXEnhancedUserInterface", kCFBooleanTrue) }
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
