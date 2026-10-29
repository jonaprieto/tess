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
