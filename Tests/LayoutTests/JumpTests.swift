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
    #expect(Config.defaults.modes["main"]?[KeySpec(key: "r", mods: [.cmd, .alt, .ctrl, .shift])] == [.jump])
    #expect(Config.defaults.modes["tess"]?[KeySpec(key: "g", mods: [])] == nil)
    #expect(Config.defaults.modes["tess"]?[KeySpec(key: "r", mods: [.cmd, .alt, .ctrl, .shift])] == [.jump])
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
