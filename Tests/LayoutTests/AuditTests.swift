import CoreGraphics
import Foundation
import Testing
@testable import Layout

@Test func resizeRejectsNonFiniteAmounts() throws {
    for bad in ["resize width nan", "resize width inf", "resize height 1e400", "resize width -inf"] {
        #expect(throws: ParseError.self, "\(bad)") { try Command.parse(bad) }
    }
    #expect(try Command.parse("resize width 100000") == [.resize(.width, 10_000)])
}

@Test func keySpellingsAreOneBinding() throws {
    // An override spelled differently replaces the default instead of competing with it.
    let c = try Config.load(Data(#"{"modes": {"main": {"shift-alt-h": "balance"}}}"#.utf8))
    #expect(c.modes["main"]?[KeySpec(key: "h", mods: [.alt, .shift])] == [.balance])
    let removed = try Config.load(Data(#"{"modes": {"main": {"shift-alt-h": null}}}"#.utf8))
    #expect(removed.modes["main"]?[KeySpec(key: "h", mods: [.alt, .shift])] == nil)
}

@Test func focusLeavingAFullscreenWindowEndsIt() {
    var w = world([[1], [2]], focused: 1)
    w.toggleFullscreen()
    #expect(w.monitors[0].fullscreen == 1)
    w.focus(.right)
    #expect(w.focused == 2)
    #expect(w.monitors[0].fullscreen == nil)
}

@Test func rebuildKeepsFullscreen() {
    var w = world([[1], [2]], focused: 1)
    w.toggleFullscreen()
    let f = w.frames(inner: 10, outer: 10)
    var unfull = w
    unfull.monitors[0].fullscreen = nil
    let tiles = unfull.frames(inner: 10, outer: 10)
    w.rebuild([(id: 1, frame: tiles[1]!), (id: 2, frame: tiles[2]!)])
    #expect(w.monitors[0].fullscreen == 1)
    #expect(w.frames(inner: 10, outer: 10)[1] == f[1])
}

@Test func gapsAreClampedAndTinyAreasSkipped() throws {
    let c = try Config.load(Data(#"{"gaps": {"inner": -4, "outer": 500}}"#.utf8))
    #expect(c.inner == 0 && c.outer == 100)
    var w = World()
    w.setMonitors([(id: "S", frame: CGRect(x: 0, y: 0, width: 100, height: 100))])
    w.insert(1)
    let f = w.frames(inner: 10, outer: 60)
    #expect(f[1] == nil || f[1]!.width >= 0 && !f[1]!.minX.isNaN)
}

@Test func rotatingADisplayFlipsItsLanes() {
    var w = World()
    w.setMonitors([(id: "D", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))])
    #expect(!w.monitors[0].rows)
    w.setMonitors([(id: "D", frame: CGRect(x: 0, y: 0, width: 1080, height: 1920))])
    #expect(w.monitors[0].rows)
}

@Test func modesCanAlwaysBeLeftTheSameWays() {
    // tess mode goes back to main; resize goes back to the mode it was entered from.
    for (mode, back) in [("tess", "main"), ("resize", "back")] {
        let m = Config.defaults.modes[mode]!
        #expect(m[KeySpec(key: "esc", mods: [])] == [.mode(back)], "\(mode) esc")
        #expect(m[KeySpec(key: "enter", mods: [])] == [.mode(back)], "\(mode) enter")
    }
    #expect(Config.defaults.modes["service"] == nil)
    let wm = Config.defaults.modes["tess"]!
    #expect(wm[KeySpec(key: "space", mods: [.alt])] == [.pick("")])
    #expect(wm[KeySpec(key: "tab", mods: [.shift])] == [.cycleMonitor(-1)])
}
