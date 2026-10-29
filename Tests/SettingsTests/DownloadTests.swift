import AppKit
import Testing
@testable import tess

@MainActor
@Test func downloadFeedbackPersistsAndTracksEachDocument() async throws {
    _ = NSApplication.shared
    let overlay = Overlay()
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let book = overlay.beginDownload("Selected book", on: screen)
    let paper = overlay.beginDownload("Selected paper", on: screen)
    let panel = try #require(overlay.downloadPanel)
    let content = try #require((panel.contentView as? NSGlassEffectView)?.contentView)
    let labels = content.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(labels == ["Downloading…\nSelected book", "Downloading…\nSelected paper"])
    #expect(content.subviews.compactMap { $0 as? NSProgressIndicator }.count == 2)
    #expect(panel.ignoresMouseEvents)
    #expect(!panel.canBecomeKey)
    #expect(screen.contains(Screens.flip(panel.frame)))
    try await Task.sleep(for: .milliseconds(1600))
    #expect(panel.isVisible)
    #expect(overlay.downloads.allSatisfy { $0.status == nil })

    overlay.finishDownload(book, status: "Opening")
    #expect(overlay.downloads.first { $0.id == book }?.title == "Selected book")
    #expect(overlay.downloads.first { $0.id == book }?.status == "Opening")
    #expect(overlay.downloads.first { $0.id == paper }?.status == nil)
    overlay.finishDownload(paper, status: "Download failed")
    #expect(overlay.downloads.first { $0.id == paper }?.status == "Download failed")
    let another = overlay.beginDownload("Another book", on: screen)
    try await Task.sleep(for: .milliseconds(4200))
    #expect(overlay.downloads.map(\.id) == [another])
    #expect(overlay.downloadPanel?.isVisible == true)
    overlay.finishDownload(another, status: "Could not open")
    try await Task.sleep(for: .milliseconds(4200))
    #expect(overlay.downloads.isEmpty)
    #expect(overlay.downloadPanel == nil)
    #expect(!panel.isVisible)
}
