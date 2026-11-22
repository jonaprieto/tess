import AppKit
import Layout
import Testing
@testable import tesela

/// `performClick` runs AppKit's event loop, and what it leaves there
/// can stop the main run loop of the test process: `exit(0)`, with
/// no summary and the remaining tests never run.
@MainActor
private func click(_ button: NSButton) {
  NSApp.sendAction(button.action!, to: button.target, from: button)
}

@Test func doctorFindsOnlyExecutableFilesInTheServicePath() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("tesela-doctor-\(UUID())")
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
@Test func menuOpensDoctorWithoutATerminal() throws {
  _ = NSApplication.shared
  let tiler = Tiler()
  let status = StatusItem(tiler)
  let menu = NSMenu()
  status.menuNeedsUpdate(menu)
  let doctor = try #require(
    menu.items.first { $0.title == "Doctor…" })
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
  click(refresh)
  #expect(report.string.contains("Configuration"))
  tiler.doctor.close()
  tiler.hotkeys.unregisterAll()
}
