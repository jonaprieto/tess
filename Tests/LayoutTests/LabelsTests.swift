import Testing
@testable import Layout

@Test func keysShowAsMacSymbols() throws {
  #expect(try KeySpec.parse("shift-1").symbol == "⇧1")
  #expect(try KeySpec.parse("alt-shift-h").symbol == "⌥⇧H")
  #expect(try KeySpec.parse("cmd-alt-ctrl-shift-g").symbol == "✦G")
  #expect(try KeySpec.parse("backspace").symbol == "⌫")
  #expect(try KeySpec.parse("esc").symbol == "⎋")
  #expect(try KeySpec.parse("enter").symbol == "↩")
  #expect(try KeySpec.parse("space").symbol == "Space")
  #expect(try KeySpec.parse("alt-shift-semicolon").symbol == "⌥⇧;")
}

@Test func commandsHavePlainLabelsAndGroups() {
  #expect(Command.moveToMonitor(2).label == "Move to screen 2")
  #expect(Command.cycleMonitor(1).label == "Next screen")
  #expect(Command.resize(.width, -50).label == "Narrower")
  #expect(Command.resize(.height, 50).label == "Taller")
  #expect(Command.exec("open -a kitty").label == "Open kitty")
  #expect(Command.mode("main").label == "Back")
  #expect(Command.nop.label == nil)
  #expect(Command.focus(.left).group == .focus)
  #expect(Command.clearMonitor.group == .move)
  #expect(Command.accordion.group == .layout)
  #expect(Command.rescue.group == .more)
}

@Test func everyDefaultBindingHasALabel() {
  for (mode, bindings) in Config.defaults.modes {
    for (key, commands) in bindings where commands != [.nop] {
      #expect(Command.label(of: commands) != nil, "\(mode) \(key)")
    }
  }
}
