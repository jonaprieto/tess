import Foundation
import Testing
@testable import Layout

@Test func jumpCommandsParse() throws {
    #expect(try Command.parse("jump") == [.jump])
    #expect(try Command.parse("focus-window 42") == [.focusWindow(42)])
    #expect(try Command.parse("swap-with 7; mode wm") == [.swapWith(7), .mode("wm")])
    #expect(throws: ParseError.self) { try Command.parse("focus-window x") }
    #expect(Command.focusWindow(42).description == "focus-window 42")
    #expect(Command.jump.label == "Jump to a window")
}

@Test func windowLabelsAreOnByDefaultAndBound() throws {
    #expect(Config.defaults.overlayWindowLabels)
    #expect(!(try Config.load(Data(#"{"overlay": {"window_labels": false}}"#.utf8))).overlayWindowLabels)
    #expect(Config.defaults.modes["main"]?[KeySpec(key: "j", mods: [.cmd, .alt, .ctrl, .shift])] == [.jump])
    #expect(Config.defaults.modes["wm"]?[KeySpec(key: "g", mods: [])] == [.jump])
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
