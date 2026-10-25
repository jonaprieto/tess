import CoreGraphics
import Testing
@testable import Layout

func near(_ a: CGRect?, _ b: CGRect?, _ tolerance: Double = 1) -> Bool {
    guard let a, let b else { return false }
    return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

@Test func twoLanesSplitTheWidthMinusGaps() {
    let f = world([[1], [2]]).frames(inner: 10, outer: 10)
    #expect(f[1] == CGRect(x: 10, y: 10, width: 485, height: 780))
    #expect(f[2] == CGRect(x: 505, y: 10, width: 485, height: 780))
}

@Test func weightsSetTheProportions() {
    var w = world([[1], [2]])
    w.monitors[0].lanes[0].size = 2
    let f = w.frames(inner: 10, outer: 10)
    #expect(abs(f[1]!.width - 2 * f[2]!.width) <= 2)
    #expect(f[2]!.maxX == 990)
}

@Test func framesStayInsideAndApart() {
    let w = world([[1, 2], [3], [4, 5, 6]], [[7]])
    let f = w.frames(inner: 10, outer: 10)
    #expect(f.count == 7)
    for (m, mon) in w.monitors.enumerated() {
        let area = mon.frame.insetBy(dx: 10, dy: 10)
        for id in mon.windows {
            #expect(area.contains(f[id]!), "window \(id) on monitor \(m)")
        }
    }
    let ids = Array(f.keys)
    for a in ids {
        for b in ids where a < b {
            #expect(!f[a]!.intersects(f[b]!), "\(a) and \(b) overlap")
        }
    }
}

@Test func accordionGivesEveryWindowTheLane() {
    var w = world([[1, 2], [3]])
    w.monitors[0].lanes[0].accordion = true
    let f = w.frames(inner: 10, outer: 10)
    #expect(f[1] == f[2])
    #expect(f[1] == CGRect(x: 10, y: 10, width: 485, height: 780))
}

@Test func fullscreenTakesTheMonitor() {
    var w = world([[1, 2], [3]], focused: 3)
    w.toggleFullscreen()
    #expect(w.frames(inner: 10, outer: 10)[3] == CGRect(x: 10, y: 10, width: 980, height: 780))
}

@Test func rowsStackLanesVertically() {
    var w = World()
    w.setMonitors([(id: "T", frame: CGRect(x: 0, y: 0, width: 800, height: 1200))])
    w.insert(1)
    w.insert(2)
    let f = w.frames(inner: 10, outer: 10)
    #expect(f[1] == CGRect(x: 10, y: 10, width: 780, height: 585))
    #expect(f[2] == CGRect(x: 10, y: 605, width: 780, height: 585))
}

@Test func rebuildFromFramesRoundTrips() {
    var w = world([[1, 2], [3]], [[4], [5, 6]])
    w.monitors[0].lanes[0].size = 3
    w.monitors[1].lanes[1].sizes = [1, 2]
    let f = w.frames(inner: 10, outer: 10)

    var back = world([], [])
    back.rebuild(f.map { (id: $0.key, frame: $0.value) })
    #expect(lanes(back) == lanes(w))
    #expect(lanes(back, 1) == lanes(w, 1))
    let g = back.frames(inner: 10, outer: 10)
    for (id, r) in f {
        #expect(near(g[id], r), "window \(id): \(String(describing: g[id])) vs \(r)")
    }
}

@Test func rebuildPutsLostWindowsOnTheActiveMonitor() {
    var w = world([], [])
    w.rebuild([
        (id: 1, frame: CGRect(x: 10, y: 10, width: 400, height: 400)),
        (id: 2, frame: CGRect(x: 1999, y: 799, width: 600, height: 600)),
        (id: 3, frame: CGRect(x: 900, y: 10, width: 400, height: 400)),
    ])
    #expect(lanes(w) == [[1], [2]])
    #expect(lanes(w, 1) == [[3]])
}

@Test func rebuildSeparatesWindowsThatOnlyPartlyOverlap() {
    var w = world([])
    w.rebuild([
        (id: 1, frame: CGRect(x: 10, y: 10, width: 980, height: 500)),
        (id: 2, frame: CGRect(x: 280, y: 300, width: 400, height: 300)),
        (id: 3, frame: CGRect(x: 10, y: 520, width: 980, height: 270)),
    ])
    #expect(lanes(w) == [[1, 3], [2]])
}

@Test func windowsOnTopOfEachOtherBecomeAnAccordion() {
    var w = world([])
    w.rebuild([
        (id: 1, frame: CGRect(x: 10, y: 10, width: 980, height: 780)),
        (id: 2, frame: CGRect(x: 10, y: 10, width: 980, height: 780)),
        (id: 3, frame: CGRect(x: 12, y: 14, width: 970, height: 770)),
    ])
    #expect(lanes(w) == [[1, 2, 3]])
    #expect(w.monitors[0].lanes[0].accordion)
    var stacked = world([])
    stacked.rebuild([
        (id: 1, frame: CGRect(x: 10, y: 10, width: 980, height: 385)),
        (id: 2, frame: CGRect(x: 10, y: 405, width: 980, height: 385)),
    ])
    #expect(!stacked.monitors[0].lanes[0].accordion)
}
