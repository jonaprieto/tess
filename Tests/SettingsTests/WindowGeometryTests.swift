import AppKit
import Layout
import Testing
@testable import tess

@MainActor
@Test func overlaysFollowTheActualWindowWhenAResizeIsRefused() throws {
    _ = NSApplication.shared
    let tiler = Tiler()
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    tiler.world.monitors = [Monitor(id: "A", frame: screen)]
    tiler.world.insert(1)
    let requested = CGRect(x: 10, y: 10, width: 400, height: 780)
    let actual = CGRect(x: 10, y: 10, width: 668, height: 780)
    tiler.infos[1] = WinInfo(id: 1, pid: 1, frame: requested, title: "", standard: true,
                             fullscreenButton: true, nativeFullscreen: false)
    let stack = [(id: WindowID(1), frame: actual)]
    let border = try #require(tiler.decorationWindows(in: stack, focused: 1, all: false).first)
    #expect(border.frame == actual)
    #expect(tiler.grayScreens(focused: 1, in: stack).first?.hole == actual)
    #expect(tiler.decorationWindows(in: [], focused: 1, all: false).isEmpty)
    #expect(tiler.grayScreens(focused: 1, in: []).isEmpty)
}

@MainActor
@Test func floatingWindowsKeepTheirRealEdgesAcrossScreens() throws {
    _ = NSApplication.shared
    let tiler = Tiler()
    tiler.world.monitors = [Monitor(id: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                            Monitor(id: "B", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))]
    tiler.world.floating.insert(1)
    let actual = CGRect(x: 800, y: 100, width: 600, height: 500)
    tiler.infos[1] = WinInfo(id: 1, pid: 1, frame: .zero, title: "", standard: true,
                             fullscreenButton: true, nativeFullscreen: false)
    let stack = [(id: WindowID(1), frame: actual)]
    let border = try #require(tiler.decorationWindows(in: stack, focused: 1, all: true).first)
    #expect(border.frame == actual)
    #expect(tiler.grayScreens(focused: 1, in: stack).compactMap(\.hole) == [actual, actual])
    #expect(tiler.targets[1] == nil)
}

/// An app that keeps its own size, with other apps' snapshots arriving between its answers.
@MainActor
@Test func onlyTheAppsOwnReportEndsARefusal() throws {
    _ = NSApplication.shared
    let tiler = Tiler()
    tiler.starting = false
    let pid = getpid()
    let worker = AppWorker(.current, onSnapshot: { _, _, _ in }, onDrag: { _ in })
    defer { worker.stop() }
    tiler.workers[pid] = worker
    tiler.world.monitors = [Monitor(id: "A", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))]
    tiler.world.insert(1)
    let target = try #require(tiler.targets[1])
    func report(_ frame: CGRect) {
        tiler.snapshot(pid, [WinInfo(id: 1, pid: pid, frame: frame, title: "", standard: true, fullscreenButton: true,
                                     nativeFullscreen: false)], nil)
    }
    let kept = CGRect(x: target.minX, y: target.minY, width: 668, height: target.height)
    report(kept)
    for _ in 1...3 {
        tiler.apply()
        tiler.apply()
        report(kept)
    }
    tiler.apply()
    #expect(tiler.refused.contains(1))
    #expect(tiler.writes[1]?.tries == 3)
    tiler.apply()
    #expect(tiler.refused.contains(1))
    report(target)
    tiler.apply()
    #expect(!tiler.refused.contains(1))
}
