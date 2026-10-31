import AppKit
import Carbon
import Layout
import Testing
@testable import tess

@MainActor
@Test func unavailableCommandSpaceDoesNotDisableOtherBindings() throws
{
  _ = NSApplication.shared
  var reserved: EventHotKeyRef?
  let result = RegisterEventHotKey(
    UInt32(kVK_Space), UInt32(cmdKey),
    EventHotKeyID(signature: 0x74657374, id: 1),
    GetApplicationEventTarget(), 0, &reserved)
  defer { if let reserved { UnregisterEventHotKey(reserved) } }
  #expect(result == noErr || result == eventHotKeyExistsErr)
  let hotkeys = Hotkeys { _ in }
  defer { hotkeys.unregisterAll() }
  let key = KeySpec(key: "space", mods: [.cmd])
  #expect(hotkeys.register([:]).isEmpty)
  #expect(hotkeys.register([key: [.pick("")]]).isEmpty)
  #expect(hotkeys.register([key: [.nop]]) == [key.description])
}

@MainActor
@Test func commandSpaceClosesThePickerWithoutChoosingAResult() throws
{
  _ = NSApplication.shared
  let picker = Picker()
  var cancelled = false
  picker.onCancel = { cancelled = true }
  picker.open(
    [], on: CGRect(x: 0, y: 0, width: 1200, height: 800), fixed: nil,
    verbs: [:]
  ) { _ in
    Picker.Map(monitors: [], windows: [], labels: [:])
  }
  let emoji = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: [.command, .control], timestamp: 0,
      windowNumber: 0, context: nil, characters: " ",
      charactersIgnoringModifiers: " ",
      isARepeat: false, keyCode: 49))
  #expect(picker.keyMonitor(emoji) === emoji)
  #expect(picker.isOpen)
  let event = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0,
      windowNumber: 0, context: nil, characters: " ",
      charactersIgnoringModifiers: " ",
      isARepeat: false, keyCode: 49))
  #expect(picker.keyMonitor(event) == nil)
  #expect(cancelled)
  #expect(!picker.isOpen)
}
