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
    #expect(throws: ParseError.self) { try Config.load(Data(typo.utf8)) }
    do {
        _ = try Config.load(Data(typo.utf8))
    } catch {
        #expect("\(error)".contains("modes.main.alt-h"))
    }
    let noMode = #"{"modes": {"main": {"alt-r": "mode nowhere"}}}"#
    #expect(throws: ParseError.self) { try Config.load(Data(noMode.utf8)) }
    #expect(throws: ParseError.self) { try Config.load(Data("{".utf8)) }
}

@Test func theFileGoesOnTopOfTheDefaults() throws {
    #expect(try Config.load(Data("{}".utf8)) == Config.defaults)
    #expect(try Config.load(nil) == Config.defaults)
    // An old full copy of the defaults still gets bindings added since.
    let old = #"{"modes": {"main": {"alt-h": "focus left"}}}"#
    let c = try Config.load(Data(old.utf8))
    #expect(c.modes["main"]?[KeySpec(key: "g", mods: [.cmd, .alt, .ctrl, .shift])] == [.pick])
    // null removes a default binding; lists replace.
    let edits = #"{"float": [], "gaps": {"inner": 4}, "modes": {"main": {"alt-t": null, "alt-y": "balance"}}}"#
    let e = try Config.load(Data(edits.utf8))
    #expect(e.float.isEmpty)
    #expect(e.inner == 4 && e.outer == 10)
    #expect(e.modes["main"]?[KeySpec(key: "t", mods: [.alt])] == nil)
    #expect(e.modes["main"]?[KeySpec(key: "y", mods: [.alt])] == [.balance])
    #expect(e.verbs["cd"] == "iTerm")
}

@Test func overridesKeepOnlyWhatChanged() throws {
    let base = Config.defaultRaw
    #expect(Config.overrides(base, over: base) == Config.Raw())
    var edited = base
    edited.gaps = .init(inner: 6, outer: 10)
    edited.modes?["main"]?["alt-t"] = nil
    edited.modes?["main"]?["alt-y"] = "balance"
    edited.verbs?["ssh"] = "iTerm"
    edited.ignore = ["io.github.ender-wang.EdgeMark", "com.example.app"]
    let o = Config.overrides(edited, over: base)
    #expect(o.float == nil && o.tile == nil)
    #expect(o.modes?["main"]?.count == 2)
    #expect(o.modes?["main"]?["alt-t"] == .some(nil))
    #expect(Config.merged(base, o) == edited)
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

@Test func hyperTTogglesTheWMMode() throws {
    let c = Config.defaults
    let hyperT = KeySpec(key: "t", mods: [.cmd, .alt, .ctrl, .shift])
    #expect(c.modes["main"]?[hyperT] == [.mode("wm")])
    let wm = try #require(c.modes["wm"])
    #expect(wm[hyperT] == [.mode("main")])
    #expect(wm[KeySpec(key: "esc", mods: [])] == [.mode("main")])
    #expect(wm[KeySpec(key: "h", mods: [])] == [.focus(.left)])
    #expect(wm[KeySpec(key: "l", mods: [.shift])] == [.move(.right)])
    #expect(wm[KeySpec(key: "2", mods: [.shift])] == [.moveToMonitor(2)])
    #expect(wm[KeySpec(key: "c", mods: [.shift])] == [.close])
    #expect(wm[KeySpec(key: "c", mods: [])] == nil)
    #expect(wm.count == 32)
    #expect(wm[KeySpec(key: "x", mods: [])] == [.closeReplace])
    #expect(c.modes["main"]?[KeySpec(key: "g", mods: [.cmd, .alt, .ctrl, .shift])] == [.pick])
}
