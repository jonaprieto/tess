import Foundation
import Testing
@testable import Layout

@Test func commandsParse() throws {
    #expect(try Command.parse("focus left") == [.focus(.left)])
    #expect(try Command.parse("resize width -50") == [.resize(.width, -50)])
    #expect(try Command.parse("resize height +50") == [.resize(.height, 50)])
    #expect(try Command.parse("focus-monitor 2") == [.focusMonitor(2)])
    #expect(try Command.parse("focus-monitor prev") == [.cycleMonitor(-1)])
    #expect(try Command.parse("move-to-monitor 3") == [.moveToMonitor(3)])
    #expect(try Command.parse("retile; mode main") == [.retile, .mode("main")])
}

@Test func execTakesTheRestOfTheLine() throws {
    #expect(try Command.parse("exec open -a kitty; echo hi") == [.exec("open -a kitty; echo hi")])
    #expect(try Command.parse("balance; exec open x") == [.balance, .exec("open x")])
}

@Test func badCommandsSayWhatIsWrong() {
    for bad in ["jump left", "focus sideways", "resize width", "focus-monitor 0", "", "balance;"] {
        #expect(throws: ParseError.self, "\(bad)") { try Command.parse(bad) }
    }
    do {
        _ = try Command.parse("jump left")
    } catch {
        #expect("\(error)".contains("jump left"))
    }
}

@Test func keySpecsParse() throws {
    #expect(try KeySpec.parse("alt-shift-h") == KeySpec(key: "h", mods: [.alt, .shift]))
    #expect(try KeySpec.parse("cmd-alt-ctrl-shift-semicolon") == KeySpec(key: "semicolon", mods: [.cmd, .alt, .ctrl, .shift]))
    #expect(try KeySpec.parse("esc") == KeySpec(key: "esc", mods: []))
    for bad in ["hyper-h", "alt-alt-h", "alt-", "alt-shift-hh"] {
        #expect(throws: ParseError.self, "\(bad)") { try KeySpec.parse(bad) }
    }
}

@Test func defaultsCoverTheSpec() throws {
    let c = Config.defaults
    #expect(c.inner == 10 && c.outer == 10)
    #expect(c.ignore == ["io.github.ender-wang.EdgeMark"])
    #expect(c.tile == ["com.anthropic.claudefordesktop"])
    #expect(c.float.contains("com.apple.finder"))
    let main = try #require(c.modes["main"])
    #expect(main[KeySpec(key: "h", mods: [.alt])] == [.focus(.left)])
    #expect(main[KeySpec(key: "semicolon", mods: [.alt, .shift])] == [.mode("service")])
    #expect(main[KeySpec(key: "h", mods: [.cmd])] == [.nop])
    #expect(c.modes["resize"]?[KeySpec(key: "esc", mods: [])] == [.mode("main")])
    #expect(c.modes["service"]?[KeySpec(key: "w", mods: [])] == [.rescue, .mode("main")])
    #expect(!main.keys.contains(KeySpec(key: "backtick", mods: [.ctrl])))
}

@Test func badConfigNamesThePlace() {
    let typo = #"{"modes": {"main": {"alt-h": "focus lefty"}}}"#
    #expect(throws: ParseError.self) { try Config.decode(Data(typo.utf8)) }
    do {
        _ = try Config.decode(Data(typo.utf8))
    } catch {
        #expect("\(error)".contains("modes.main.alt-h"))
    }
    let noMode = #"{"modes": {"main": {"alt-r": "mode resize"}}}"#
    #expect(throws: ParseError.self) { try Config.decode(Data(noMode.utf8)) }
    let noMain = #"{"modes": {"other": {}}}"#
    #expect(throws: ParseError.self) { try Config.decode(Data(noMain.utf8)) }
    #expect(throws: ParseError.self) { try Config.decode(Data("{".utf8)) }
}

@Test func minimalConfigUsesDefaultGaps() throws {
    let c = try Config.decode(Data(#"{"modes": {"main": {}}}"#.utf8))
    #expect(c.inner == 10 && c.outer == 10)
    #expect(c.ignore.isEmpty)
}

@Test func descriptionsParseBack() throws {
    for (_, bindings) in Config.defaults.modes {
        for (_, commands) in bindings {
            for c in commands { #expect(try Command.parse(c.description) == [c], "\(c)") }
        }
    }
    #expect(Command.resize(.width, -50).description == "resize width -50")
    #expect(Command.resize(.height, 12.5).description == "resize height +12.5")
}
