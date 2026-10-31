import AppKit
import Testing
@testable import tess

@MainActor
@Test func pickerConsumesHandledKeysAndPassesTypingThrough() throws {
  _ = NSApplication.shared
  let picker = Picker()
  let monitor = picker.keyMonitor
  func event(_ key: UInt16, _ characters: String) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false,
        keyCode: key))
  }
  for (key, characters) in [
    (UInt16(53), "\u{1b}"), (125, "\u{f701}"), (126, "\u{f700}"),
    (36, "\r"), (48, "\t")
  ] {
    #expect(try monitor(event(key, characters)) == nil)
  }
  let letter = try event(0, "a")
  #expect(monitor(letter) === letter)
}

private final class ClipboardEditor: NSTextView {
  var actions: [String] = []
  override func paste(_ sender: Any?) { actions.append("paste") }
  override func copy(_ sender: Any?) { actions.append("copy") }
  override func cut(_ sender: Any?) { actions.append("cut") }
  override func selectAll(_ sender: Any?) {
    actions.append("selectAll")
  }
}

@MainActor
@Test func pickerRoutesClipboardShortcutsToItsTextEditor() throws {
  _ = NSApplication.shared
  let picker = Picker()
  let panel = KeyPanel(
    contentRect: .zero, styleMask: [.borderless], backing: .buffered,
    defer: false)
  let editor = ClipboardEditor()
  panel.contentView = editor
  #expect(panel.makeFirstResponder(editor))
  for (key, character, action) in [
    (UInt16(9), "v", "paste"), (8, "c", "copy"), (7, "x", "cut"),
    (0, "a", "selectAll")
  ] {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
        characters: character, charactersIgnoringModifiers: character,
        isARepeat: false, keyCode: key))
    #expect(picker.keyMonitor(event) === event)
    #expect(panel.performKeyEquivalent(with: event))
    #expect(editor.actions.last == action)
  }
  let modified = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: [.command, .control],
      timestamp: 0, windowNumber: panel.windowNumber, context: nil,
      characters: "v", charactersIgnoringModifiers: "v",
      isARepeat: false, keyCode: 9))
  _ = panel.performKeyEquivalent(with: modified)
  #expect(editor.actions == ["paste", "copy", "cut", "selectAll"])
}
