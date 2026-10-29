import AppKit
import Testing
@testable import tess

@MainActor
private func recallKey(_ picker: Picker, _ code: UInt16, _ text: String) throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: text,
                                            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    #expect(picker.keyMonitor(event) == nil)
}

@MainActor
private func openRecallPicker(_ picker: Picker, text: String, needsPlacement: Bool = false, search: String? = nil) {
    let item = Picker.Item(kind: needsPlacement ? .window(1) : .copy("result"), title: "Result", detail: "", search: search ?? text)
    picker.open([item], on: CGRect(x: 0, y: 0, width: 1200, height: 800), fixed: nil, verbs: [:], text: text) { _ in
        Picker.Map(monitors: [], windows: [], labels: [:])
    }
}

@MainActor
@Test func pickerRecallPersistsDeduplicatesAndStaysBounded() throws {
    _ = NSApplication.shared
    let suite = "tess-picker-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set((0..<100).map { "book query \($0)" }, forKey: "pickerRecentQueries")
    let picker = Picker(defaults: defaults)
    openRecallPicker(picker, text: "BOOK query 50")
    try recallKey(picker, 36, "\r")
    #expect(picker.recentQueries.count == 100)
    #expect(picker.recentQueries.first == "BOOK query 50")
    #expect(!picker.recentQueries.contains("book query 50"))
    openRecallPicker(picker, text: "paper distributed systems")
    try recallKey(picker, 36, "\r")
    #expect(picker.recentQueries.count == 100)
    #expect(!picker.recentQueries.contains("book query 99"))
    let restored = Picker(defaults: defaults)
    #expect(restored.completion(for: "PAPER dis") == "paper distributed systems")
    #expect(restored.completion(for: "") == "paper distributed systems")
    #expect(restored.completion(for: "paper distributed systems") == nil)
    #expect(restored.completion(for: "unknown") == nil)
}

@MainActor
@Test func pickerRecallWaitsForConfirmationAndIgnoresCancellation() throws {
    _ = NSApplication.shared
    let picker = Picker()
    openRecallPicker(picker, text: "cancelled query", needsPlacement: true)
    try recallKey(picker, 36, "\r")
    #expect(picker.recentQueries.isEmpty)
    picker.close()
    #expect(picker.recentQueries.isEmpty)
    openRecallPicker(picker, text: "confirmed query", needsPlacement: true)
    try recallKey(picker, 36, "\r")
    try recallKey(picker, 5, "g")
    #expect(picker.recentQueries == ["confirmed query"])
    openRecallPicker(picker, text: "another cancelled query")
    try recallKey(picker, 53, "\u{1b}")
    #expect(picker.recentQueries == ["confirmed query"])
    openRecallPicker(picker, text: "")
    try recallKey(picker, 36, "\r")
    #expect(picker.recentQueries == ["confirmed query"])
}

@MainActor
@Test func tabRecallsTheQueryWithoutRunningIt() throws {
    _ = NSApplication.shared
    let picker = Picker()
    openRecallPicker(picker, text: "paper distributed systems")
    try recallKey(picker, 36, "\r")
    var selections = 0
    picker.onDone = { _, _ in selections += 1 }
    openRecallPicker(picker, text: "pap", search: "paper distributed systems")
    try recallKey(picker, 48, "\t")
    #expect(picker.isOpen)
    #expect(selections == 0)
    try recallKey(picker, 36, "\r")
    #expect(selections == 1)
    #expect(picker.recentQueries == ["paper distributed systems"])
    openRecallPicker(picker, text: "", search: "paper distributed systems")
    try recallKey(picker, 48, "\t")
    #expect(picker.isOpen)
    #expect(selections == 1)
    picker.close()
}

@MainActor
@Test func folderCompletionKeepsPriorityOverRecall() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tess-recall-\(UUID())")
    let folder = directory.appendingPathComponent("alpha")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let picker = Picker()
    let remembered = "cd \(directory.path)/another"
    openRecallPicker(picker, text: remembered)
    try recallKey(picker, 36, "\r")
    var opened: String?
    picker.onDone = { item, _ in
        if case .open(_, let path) = item.kind { opened = path }
    }
    picker.open([], on: CGRect(x: 0, y: 0, width: 1200, height: 800), fixed: .here,
                verbs: ["cd": "iTerm"], text: "cd \(directory.path)/a") { _ in
        Picker.Map(monitors: [], windows: [], labels: [:])
    }
    try recallKey(picker, 48, "\t")
    try recallKey(picker, 36, "\r")
    #expect(opened == folder.path)
    #expect(picker.recentQueries.first == "cd \(folder.path)/")
}
