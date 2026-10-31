import AppKit
import Layout
import Testing
@testable import tess

@MainActor
@Test func closingPickerReleasesResultsAndPlacementData() throws {
  _ = NSApplication.shared
  let picker = Picker()
  let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
  let enter = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0,
      windowNumber: 0, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
    ))
  weak var retainedIcon: NSImage?
  autoreleasepool {
    let icon = NSImage(size: NSSize(width: 40, height: 40))
    retainedIcon = icon
    let item = Picker.Item(
      kind: .window(1), title: "Window", detail: "", icon: icon,
      search: "Window")
    picker.open([item], on: screen, fixed: nil, verbs: [:]) { _ in
      Picker.Map(
        monitors: [screen],
        windows: [(1, screen, "App", "Window", icon)],
        labels: [1: "a"])
    }
    _ = picker.keyMonitor(enter)
    picker.close()
  }
  #expect(!picker.isOpen)
  #expect(retainedIcon == nil)

  var chosen: String?
  picker.onDone = { item, _ in chosen = item.title }
  picker.open(
    [
      Picker.Item(
        kind: .copy("42"), title: "42", detail: "", search: "42")
    ],
    on: screen, fixed: nil, verbs: [:]
  ) { _ in Picker.Map(monitors: [], windows: [], labels: [:]) }
  _ = picker.keyMonitor(enter)
  #expect(chosen == "42")
  #expect(!picker.isOpen)
}

@MainActor
@Test func closingSwitcherReleasesRenderedCards() {
  let switcher = Switcher()
  weak var retainedIcon: NSImage?
  autoreleasepool {
    let icon = NSImage(size: NSSize(width: 40, height: 40))
    retainedIcon = icon
    switcher.open(
      [
        Switcher.Card(
          target: .window(1), icon: icon, app: "App", title: "Window",
          detail: "", label: "a")
      ],
      selected: 0, on: CGRect(x: 0, y: 0, width: 1200, height: 800))
    switcher.retitle { _ in "Updated" }
    switcher.close()
  }
  #expect(switcher.cards.isEmpty)
  #expect(switcher.pick == nil)
  #expect(retainedIcon == nil)
}

@MainActor
@Test func closingPickerCancelsDebouncedSearch() async throws {
  _ = NSApplication.shared
  let picker = Picker()
  var searches = 0
  picker.search = { _, _, _ in searches += 1 }
  picker.open(
    [], on: CGRect(x: 0, y: 0, width: 1200, height: 800), fixed: nil,
    verbs: ["f": "search:files"], text: "f example"
  ) { _ in
    Picker.Map(monitors: [], windows: [], labels: [:])
  }
  picker.close()
  try await Task.sleep(for: .milliseconds(250))
  #expect(searches == 0)
}
