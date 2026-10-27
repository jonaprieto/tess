import Foundation
import Testing
@testable import Layout

@Test func jumpCommandsParse() throws {
    #expect(try Command.parse("jump") == [.jump])
    #expect(try Command.parse("focus-window 42") == [.focusWindow(42)])
    #expect(try Command.parse("swap-with 7; mode tess") == [.swapWith(7), .mode("tess")])
    #expect(throws: ParseError.self) { try Command.parse("focus-window x") }
    #expect(Command.focusWindow(42).description == "focus-window 42")
    #expect(Command.jump.label == "Jump to a window")
}

@Test func windowLabelsShowWhenJumpingByDefault() throws {
    #expect(Config.defaults.windowLabels == .jump)
    #expect(try Config.load(Data(#"{"overlay": {"window_labels": "always"}}"#.utf8)).windowLabels == .always)
    #expect(try Config.load(Data(#"{"overlay": {"window_labels": "off"}}"#.utf8)).windowLabels == .off)
    #expect(throws: ParseError.self) { try Config.load(Data(#"{"overlay": {"window_labels": true}}"#.utf8)) }
    #expect(throws: ParseError.self) { try Config.load(Data(#"{"overlay": {"window_labels": "sometimes"}}"#.utf8)) }
    #expect(Config.defaults.modes["tess"]?[KeySpec(key: "g", mods: [])] == nil)
}

@Test func labelsStayWithTheirWindows() {
    var l = stableLabels([:], windows: [1, 2, 3], alphabet: "asd")
    #expect(l == [1: "a", 2: "s", 3: "d"])
    // 2 closes, 4 opens: 1 and 3 keep theirs, 4 takes the freed letter.
    l = stableLabels(l, windows: [3, 4, 1], alphabet: "asd")
    #expect(l == [1: "a", 3: "d", 4: "s"])
    // More windows than letters: the rest go unlabeled.
    l = stableLabels(l, windows: [1, 3, 4, 5], alphabet: "asd")
    #expect(l[5] == nil && l.count == 3)
}

@Test func theOldWmModeIsGone() throws {
    #expect(throws: ParseError.self) {
        try Config.load(Data(#"{"modes": {"main": {"cmd-alt-ctrl-shift-t": "mode wm"}}}"#.utf8))
    }
}

@Test func screenKeysFollowTheScreensThereAre() {
    let tess = Config.defaults.modes["tess"]!
    let two = forScreens(tess, 2)
    #expect(two[KeySpec(key: "2", mods: [])] == [.focusMonitor(2)])
    #expect(two[KeySpec(key: "3", mods: [])] == nil && two[KeySpec(key: "3", mods: [.shift])] == nil)
    #expect(two.count == tess.count - 2)
    #expect(forScreens(tess, 3) == tess)
}

@Test func lettersAreTheOnesTessModeLeavesFree() throws {
    let pool = labelLetters(free: Config.defaults.modes["tess"]!)
    #expect(pool == "dqeyiocm")
    // No letter the picker's map uses for itself either (g jumps, f floats).
    #expect(!pool.contains("g") && !pool.contains("f"))
    // A letter that leaves the pool leaves its window.
    #expect(stableLabels([1: "a", 2: "d"], windows: [1, 2], alphabet: pool) == [1: "q", 2: "d"])
    // Tabs take letters after the windows and select by place.
    let (keys, _) = jumpKeys(labels: [1: "d"], windows: [1], tabs: ["q", "e"], screens: 1, back: [.mode("main")])
    #expect(keys[KeySpec(key: "e", mods: [])] == [.focusTab(1), .mode("main")])
    #expect(try Command.parse("focus-tab 3") == [.focusTab(3)])
    #expect(Command.focusTab(3).description == "focus-tab 3")
}

@Test func onlyTheFrontWindowAtAPointIsLabeled() {
    // 2 covers the right half of 1.
    let stack: [(id: WindowID, frame: CGRect)] = [(2, CGRect(x: 500, y: 0, width: 500, height: 800)),
                                                  (1, CGRect(x: 0, y: 0, width: 1000, height: 800))]
    #expect(onTop(CGPoint(x: 250, y: 400), 1, stack))
    #expect(!onTop(CGPoint(x: 750, y: 400), 1, stack))
    #expect(onTop(CGPoint(x: 750, y: 400), 2, stack))
    #expect(!onTop(CGPoint(x: 1500, y: 400), 1, stack))
}
