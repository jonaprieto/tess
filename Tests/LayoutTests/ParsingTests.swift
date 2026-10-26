import CoreGraphics
import Foundation
import Testing
@testable import Layout

@Test func arxivQueriesDropStopwords() {
    #expect(Parse.arxivQuery("Attention is all you need Vaswani") == "all:attention AND all:need AND all:vaswani")
}

@Test func arxivEntriesBecomePapers() {
    let xml = """
        <feed><title>query</title><entry><id>http://arxiv.org/abs/1706.03762v7</id>
        <published>2017-06-12T17:57:34Z</published><title>Attention Is All
          You Need</title><author><name>Ashish Vaswani</name></author><author><name>Noam Shazeer</name></author>
        <author><name>Niki Parmar</name></author></entry></feed>
        """
    let p = Parse.arxiv(xml)
    #expect(p.count == 1)
    #expect(p[0].id == "1706.03762v7")
    #expect(p[0].title == "Attention Is All You Need")
    #expect(p[0].fileName == "2017-vaswani-attention-is-all-you-need.pdf")
    #expect(p[0].detail == "arXiv · Ashish Vaswani, Noam Shazeer et al. · 2017")
    #expect(p[0].pdf == URL(string: "https://arxiv.org/pdf/1706.03762v7"))
}

@Test func folioResultsBecomeBooks() {
    let json = #"[{"md5": "abc", "title": "SICP", "author": "Abelson", "year": "1996", "ext": "pdf", "size": "4 MB"}, {"title": "no md5"}]"#
    #expect(Parse.folio(json) == [Parse.Book(md5: "abc", title: "SICP", detail: "Abelson · 1996 · pdf · 4 MB", ext: "pdf")])
    #expect(Parse.folio("not json").isEmpty)
}

@Test func rgLinesBecomeMatches() {
    #expect(Parse.rg("./tess/Sources/x.swift:12:   let a: Int = 1") ==
            Parse.Match(path: "tess/Sources/x.swift", line: 12, text: "let a: Int = 1"))
    #expect(Parse.rg("garbage") == nil)
}

@Test func browserLinesBecomeTabsAndPages() {
    #expect(Parse.tab("123\t2\tPull request\thttps://github.com/a/b/pull/1") ==
            Parse.Tab(window: 123, index: 2, title: "Pull request", url: "https://github.com/a/b/pull/1"))
    #expect(Parse.tab("123\t2\t\thttps://x.org")?.title == "https://x.org")
    #expect(Parse.page("Slack\thttps://app.slack.com/client")?.host == "app.slack.com")
    #expect(Parse.page("Settings\tchrome://settings") == nil)
    #expect(Parse.short("/Users/j/anoma", home: "/Users/j") == "~/anoma")
}

@Test func windowsAreTiledFloatedOrLeftAlone() {
    var c = Config.defaults
    c.float = ["com.apple.finder"]
    c.tile = ["com.anthropic.claudefordesktop"]
    let w = WinInfo(id: 1, pid: 1, frame: .zero, title: "", standard: true, fullscreenButton: true, nativeFullscreen: false)
    #expect(w.kind(bundleID: "com.example", c) == .tile)
    #expect(w.kind(bundleID: "com.apple.finder", c) == .float)
    var dialog = w
    dialog.fullscreenButton = false
    #expect(dialog.kind(bundleID: "com.example", c) == .float)
    #expect(dialog.kind(bundleID: "com.anthropic.claudefordesktop", c) == .tile)
    var minimized = w
    minimized.standard = false
    #expect(minimized.kind(bundleID: "com.example", c) == .skip)
}

@Test func geometryHelpers() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    #expect(CGRect(x: 0, y: 0, width: 100, height: 100).isNear(CGRect(x: 1, y: 0, width: 100, height: 99)))
    #expect(!CGRect(x: 0, y: 0, width: 100, height: 100).isNear(CGRect(x: 2, y: 0, width: 100, height: 100)))
    #expect(CGRect.centered(CGSize(width: 2000, height: 100), in: screen) == CGRect(x: 50, y: 350, width: 900, height: 100))
    #expect(CGRect(x: 995, y: 795, width: 400, height: 400).isLost(on: [screen]))
    #expect(!CGRect(x: 10, y: 10, width: 400, height: 400).isLost(on: [screen]))
}

@Test func jumpKeysCoverLettersScreensAndExits() {
    let (keys, exits) = jumpKeys(labels: [7: "a", 9: "s"], windows: [7, 9, 11], screens: 2, back: [.mode("main")])
    #expect(keys[KeySpec(key: "a", mods: [])] == [.focusWindow(7), .mode("main")])
    #expect(keys[KeySpec(key: "s", mods: [.shift])] == [.swapWith(9), .mode("main")])
    #expect(keys[KeySpec(key: "2", mods: [])] == [.focusMonitor(2), .mode("main")])
    #expect(keys[KeySpec(key: "3", mods: [])] == nil)
    #expect(keys[KeySpec(key: "1", mods: [.shift])] == [.moveToMonitor(1), .mode("main")])
    #expect(exits.allSatisfy { keys[$0] == [.mode("main")] })
}

@Test func arithmeticForThePicker() {
    #expect(Parse.arithmetic("2 * (3 + 4)") == 14)
    #expect(Parse.arithmetic("1/2") == 0.5)
    #expect(Parse.arithmetic("-2^2") == -4)
    #expect(Parse.arithmetic("2^3^2") == 512)
    #expect(Parse.arithmetic("10 % 3") == 1)
    #expect(Parse.arithmetic("2^-1") == 0.5)
    // Half typed, not arithmetic, or no number.
    for bad in ["2+", "(1", "1)", "", "1..2", "abc", "1/0", "2+x"] {
        #expect(Parse.arithmetic(bad) == nil, "\(bad)")
    }
    #expect(Parse.number(14) == "14")
    #expect(Parse.number(0.1 + 0.2) == "0.3")
    #expect(Parse.number(-0.0) == "0")
}
