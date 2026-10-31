import AppKit
import Layout
import Testing
@testable import tess

@Test func doctorFindsOnlyExecutableFilesInTheServicePath() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("tess-doctor-\(UUID())")
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("folio")
  try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o644], ofItemAtPath: file.path)
  #expect(Doctor.executable("folio", path: root.path) == nil)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: file.path)
  #expect(Doctor.executable("folio", path: root.path) == file.path)
  #expect(Doctor.executable(file.path, path: "") == file.path)
  #expect(Doctor.executable("missing", path: root.path) == nil)
  #expect(Doctor.executable(root.path, path: root.path) == nil)
  #expect(Doctor.executable("folio", path: "") == nil)
}

@MainActor
@Test func tutorialIsRepeatableAndUsesConfiguredShortcuts() throws {
  _ = NSApplication.shared
  let config = try Config.load(
    Data(
      #"{"modes":{"main":{"alt-t":null,"alt-g":"mode tess"}}}"#.utf8))
  let steps = Tutorial.steps(config)
  #expect(steps[3].body.contains("⌥G"))
  #expect(!steps[3].body.contains("⌥T"))
  let changedSearch = try Config.load(
    Data(#"{"verbs":{"book":null,"read":"search:books"}}"#.utf8))
  #expect(
    Tutorial.steps(changedSearch)[4].body.contains(
      "read title author"))
  #expect(
    !Tutorial.steps(changedSearch)[4].body.contains(
      "book title author"))
  #expect(try Command.parse("tutorial") == [.tutorial])
  #expect(Command.tutorial.description == "tutorial")
  for step in steps {
    let height = (step.body as NSString).boundingRect(
      with: NSSize(width: 504, height: 1000),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: NSFont.systemFont(ofSize: 15)]
    ).height
    #expect(height <= 224, "\(step.title) fits without clipping")
  }
  let tutorial = Tutorial()
  tutorial.show(config)
  #expect(tutorial.index == 0)
  tutorial.goBack()
  #expect(tutorial.index == 0)
  var practices = 0
  tutorial.onPicker = { practices += 1 }
  tutorial.goNext()
  tutorial.resume()
  #expect(tutorial.index == 1)
  let practice = try #require(
    tutorial.window?.contentView?.subviews.compactMap {
      $0 as? NSButton
    }
    .first { $0.title == "Try the Picker" })
  practice.performClick(nil)
  #expect(practices == 1)
  tutorial.goBack()
  for _ in 1..<steps.count { tutorial.goNext() }
  #expect(tutorial.index == steps.count - 1)
  tutorial.goNext()
  #expect(tutorial.window?.isVisible == false)
  tutorial.show(config)
  #expect(tutorial.index == 0)
  tutorial.close()
}

@MainActor
@Test func menuOpensDoctorAndTutorialWithoutATerminal() throws {
  _ = NSApplication.shared
  let tiler = Tiler()
  let status = StatusItem(tiler)
  let menu = NSMenu()
  status.menuNeedsUpdate(menu)
  let doctor = try #require(
    menu.items.first { $0.title == "Doctor…" })
  let tutorial = try #require(
    menu.items.first { $0.title == "Tutorial…" })
  #expect(
    NSApp.sendAction(
      try #require(doctor.action), to: doctor.target, from: doctor))
  let window = try #require(tiler.doctor.window)
  #expect(window.isVisible)
  let scroll = try #require(
    window.contentView?.subviews.compactMap { $0 as? NSScrollView }
      .first)
  let report = try #require(scroll.documentView as? NSTextView)
  #expect(report.string.contains("Binaries (service PATH:"))
  #expect(report.string.contains("folio:"))
  #expect(report.frame.width > 400)
  let refresh = try #require(
    window.contentView?.subviews.compactMap { $0 as? NSButton }.first)
  refresh.performClick(nil)
  #expect(report.string.contains("Configuration"))
  #expect(
    NSApp.sendAction(
      try #require(tutorial.action), to: tutorial.target,
      from: tutorial))
  #expect(tiler.tutorial.window?.isVisible == true)
  tiler.tutorial.goNext()
  tiler.returnToTutorial = true
  tiler.pickerClosed(cancelled: true, refocus: false)
  #expect(tiler.tutorial.index == 1)
  #expect(!tiler.returnToTutorial)
  tiler.tutorial.close()
  tiler.doctor.close()
  tiler.hotkeys.unregisterAll()
}
