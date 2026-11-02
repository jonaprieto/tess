import AppKit
import Layout
import Testing
@testable import tess

@MainActor
private func file(_ name: String) -> Picker.Item {
  Picker.Item(
    kind: .file("/home/\(name)"), title: name, detail: "~", search: ""
  )
}

@MainActor
private func match(_ title: String, search: String) -> Picker.Item {
  Picker.Item(
    kind: .copy(title), title: title, detail: "", search: search)
}

@MainActor
private func open(
  _ picker: Picker, _ items: [Picker.Item], text: String
) {
  picker.open(
    items, on: CGRect(x: 0, y: 0, width: 1200, height: 800),
    fixed: nil, verbs: [:], text: text
  ) { _ in
    Picker.Map(monitors: [], windows: [], labels: [:])
  }
}

@MainActor
private func press(
  _ picker: Picker, _ code: UInt16, _ text: String
) throws {
  let event = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0,
      windowNumber: 0, context: nil, characters: text,
      charactersIgnoringModifiers: text, isARepeat: false,
      keyCode: code))
  #expect(picker.keyMonitor(event) == nil)
}

/// Tests run side by side and each panel takes the key window from
/// the last, which closes a picker: this one ignores that.
@MainActor
private func headlessPicker() -> Picker {
  _ = NSApplication.shared
  let picker = Picker()
  picker.panel.delegate = nil
  return picker
}

@MainActor
private func wait(until done: () -> Bool) async throws {
  for _ in 0..<300 where !done() {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(done())
}

@MainActor
@Test func plainTextFindsFilesBelowWhatAlreadyMatched() async throws {
  let picker = headlessPicker()
  defer { picker.close() }
  var asked: [(PickerSearch, String)] = []
  picker.search = { kind, query, done in
    asked.append((kind, query))
    done([file("report.txt")])
  }
  open(picker, [match("Report", search: "report")], text: "report")
  try await wait { picker.shown.count == 2 }
  #expect(asked.count == 1)
  #expect(asked.first?.0 == .files && asked.first?.1 == "report")
  #expect(picker.shown.map(\.title) == ["Report", "report.txt"])
}

@MainActor
@Test func plainTextFindsFilesWhenNothingElseMatches() async throws {
  let picker = headlessPicker()
  defer { picker.close() }
  picker.search = { _, _, done in done([file("research")]) }
  open(picker, [match("Report", search: "report")], text: "research")
  try await wait { !picker.shown.isEmpty }
  #expect(picker.shown.map(\.title) == ["research"])
}

@MainActor
@Test func aFewLettersSearchNoFiles() async throws {
  let picker = headlessPicker()
  defer { picker.close() }
  var searches = 0
  picker.search = { _, _, _ in searches += 1 }
  open(picker, [], text: "re")
  try await Task.sleep(for: .milliseconds(300))
  #expect(searches == 0)
}

@MainActor
@Test func filesThatArriveLateLeaveTheSelectionAlone() async throws {
  let picker = headlessPicker()
  defer { picker.close() }
  var answer: (([Picker.Item]) -> Void)?
  picker.search = { _, _, done in answer = done }
  var picked: String?
  picker.onDone = { item, _ in picked = item.title }
  open(
    picker,
    [
      match("Report one", search: "report one"),
      match("Report two", search: "report two")
    ],
    text: "report")
  try await wait { answer != nil }
  try press(picker, 125, "\u{f701}")
  let deliver = try #require(answer)
  deliver([file("report.txt")])
  #expect(picker.shown.count == 3)
  try press(picker, 36, "\r")
  #expect(picked == "Report two")
}

@MainActor
@Test func filesFromAnOlderSearchAreDropped() async throws {
  let picker = headlessPicker()
  defer { picker.close() }
  var answers: [([Picker.Item]) -> Void] = []
  picker.search = { _, _, done in answers.append(done) }
  open(picker, [match("Report", search: "report")], text: "report")
  try await wait { answers.count == 1 }
  // Late tabs filter the list again, which starts a new search.
  picker.add([])
  try await wait { answers.count == 2 }
  answers[0]([file("old.txt")])
  #expect(picker.shown.map(\.title) == ["Report"])
  answers[1]([file("new.txt")])
  #expect(picker.shown.map(\.title) == ["Report", "new.txt"])
}

@MainActor
@Test func appsAreNotListedAgainAsFiles() async throws {
  let picker = headlessPicker()
  defer { picker.close() }
  picker.search = { _, _, done in
    done([file("Notes.app"), file("notes.txt")])
  }
  open(picker, [match("Notes", search: "notes")], text: "notes")
  try await wait { picker.shown.count > 1 }
  #expect(picker.shown.map(\.title) == ["Notes", "notes.txt"])
}
