import CoreGraphics
import Testing
@testable import Layout

let left = (id: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
let right = (id: "B", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))

/// A world with monitor A (and B when `b` is given) holding the given lanes.
func world(_ a: [[WindowID]], _ b: [[WindowID]]? = nil, focused: WindowID? = nil) -> World {
    var w = World()
    w.setMonitors(b == nil ? [left] : [left, right])
    w.monitors[0].lanes = a.map { Lane($0) }
    if let b { w.monitors[1].lanes = b.map { Lane($0) } }
    w.focused = focused
    return w
}

func lanes(_ w: World, _ m: Int = 0) -> [[WindowID]] { w.monitors[m].lanes.map(\.windows) }

@Test func insertAddsLaneRightOfFocused() {
    var w = world([])
    w.insert(1)
    w.insert(2)
    #expect(lanes(w) == [[1], [2]])
    #expect(w.focused == 2)
    w.focus(.left)
    w.insert(3)
    #expect(lanes(w) == [[1], [3], [2]])
    #expect(w.focused == 3)
}

@Test func moveFromSharedLanePopsOut() {
    var w = world([[1, 2], [3]], focused: 2)
    w.move(.right)
    #expect(lanes(w) == [[1], [2], [3]])
    w = world([[1], [2, 3]], focused: 3)
    w.move(.left)
    #expect(lanes(w) == [[1], [3], [2]])
}

@Test func moveAloneJoinsNeighbor() {
    var w = world([[1], [2, 3]], focused: 1)
    w.move(.right)
    #expect(lanes(w) == [[2, 3, 1]])
    #expect(w.focused == 1)
}

@Test func moveAloneAtEdgeCrossesMonitor() {
    var w = world([[1], [2]], [[5]], focused: 2)
    w.move(.right)
    #expect(lanes(w) == [[1]])
    #expect(lanes(w, 1) == [[2], [5]])
    #expect(w.focused == 2)
    #expect(w.activeMonitor == 1)
    w.move(.left)
    #expect(lanes(w) == [[1], [2]])
    #expect(lanes(w, 1) == [[5]])
}

@Test func moveAtEdgeWithoutMonitorDoesNothing() {
    var w = world([[1], [2]], focused: 2)
    w.move(.right)
    #expect(lanes(w) == [[1], [2]])
}

@Test func moveAlongStackSwaps() {
    var w = world([[1, 2, 3]], focused: 1)
    w.move(.down)
    #expect(lanes(w) == [[2, 1, 3]])
    w.move(.up)
    w.move(.up)
    #expect(lanes(w) == [[1, 2, 3]])
}

@Test func focusCrossesMonitorsAtTheEdge() {
    var w = world([[1], [2]], [[3], [4]], focused: 3)
    w.focus(.left)
    #expect(w.focused == 2)
    w.focus(.right)
    #expect(w.focused == 3)
    w.focus(.right)
    w.focus(.right)
    #expect(w.focused == 4)
}

@Test func focusAlongStack() {
    var w = world([[1, 2]], focused: 1)
    w.focus(.down)
    #expect(w.focused == 2)
    w.focus(.down)
    #expect(w.focused == 2)
}

@Test func removePicksTheNextFocus() {
    var w = world([[1, 2, 3]], focused: 2)
    w.remove(2)
    #expect(w.focused == 3)

    w = world([[1, 2]], focused: 2)
    w.remove(2)
    #expect(w.focused == 1)

    w = world([[1], [2], [3]], focused: 2)
    w.remove(2)
    #expect(lanes(w) == [[1], [3]])
    #expect(w.focused == 3)

    w = world([[1], [2]], focused: 2)
    w.remove(2)
    #expect(w.focused == 1)

    w = world([[1]], [[2]], focused: 2)
    w.focused = 1
    w.remove(1)
    #expect(w.focused == 2)

    w = world([[1], [2]], focused: 1)
    w.remove(2)
    #expect(w.focused == 1)
}

@Test func unplugParksAndReplugRestores() {
    var w = world([[1]], [[3], [4, 5]], focused: 1)
    w.setMonitors([left])
    #expect(w.monitors.count == 1)
    #expect(lanes(w) == [[1], [3], [4, 5]])
    w.remove(4)
    w.setMonitors([left, right])
    #expect(lanes(w) == [[1]])
    #expect(lanes(w, 1) == [[3], [5]])
    #expect(w.parked.isEmpty)
}

@Test func noMonitorsKeepsTheLayout() {
    var w = world([[1]], [[2]])
    w.setMonitors([])
    #expect(w.monitors.count == 2)
}

@Test func rowsMonitorTreatsVerticalAsLanes() {
    var w = World()
    w.setMonitors([(id: "T", frame: CGRect(x: 0, y: 0, width: 800, height: 1200))])
    #expect(w.monitors[0].rows)
    w.insert(1)
    w.insert(2)
    w.focus(.up)
    #expect(w.focused == 1)
    w.move(.down)
    #expect(lanes(w) == [[2, 1]])
    w.focus(.left)
    #expect(w.focused == 2)
}

@Test func moveToMonitorAppendsAtTheEnd() {
    var w = world([[1], [2]], [[3]], focused: 1)
    w.moveToMonitor(1)
    #expect(lanes(w) == [[2]])
    #expect(lanes(w, 1) == [[3], [1]])
    #expect(w.focused == 1)
    #expect(w.activeMonitor == 1)
}

@Test func focusMonitorPicksMostRecent() {
    var w = world([[1], [2]], [[3], [4]], focused: 4)
    w.focused = 1
    w.focusMonitor(1)
    #expect(w.focused == 4)
    w.cycleMonitor(1)
    #expect(w.focused == 1)
    w.cycleMonitor(-1)
    #expect(w.focused == 4)
}

@Test func toggleFloatingOutAndBack() {
    var w = world([[1], [2]], focused: 1)
    w.toggleFloating(1)
    #expect(lanes(w) == [[2]])
    #expect(w.floating == [1])
    #expect(w.focused == 1)
    w.toggleFloating(1)
    #expect(lanes(w) == [[2], [1]])
    #expect(w.floating.isEmpty)
}

@Test func resizeChangesTheFocusedLane() {
    var w = world([[1], [2]], focused: 1)
    w.resize(.width, by: 100)
    #expect(w.monitors[0].lanes[0].size > w.monitors[0].lanes[1].size)
    w.balance()
    #expect(w.monitors[0].lanes[0].size == w.monitors[0].lanes[1].size)
    w.resize(.width, by: -10_000)
    #expect(w.monitors[0].lanes[0].size > 0)
}

@Test func accordionAndFullscreenToggle() {
    var w = world([[1, 2]], focused: 1)
    w.toggleAccordion()
    #expect(w.monitors[0].lanes[0].accordion)
    w.toggleFullscreen()
    #expect(w.monitors[0].fullscreen == 1)
    w.toggleFullscreen()
    #expect(w.monitors[0].fullscreen == nil)
    w.toggleFullscreen()
    w.remove(1)
    #expect(w.monitors[0].fullscreen == nil)
}

@Test func clearMonitorSendsEverythingToTheNextOne() {
    var w = world([[1, 2], [3]], [[4]], focused: 1)
    w.clearMonitor()
    #expect(lanes(w).isEmpty)
    #expect(lanes(w, 1) == [[4], [1, 2], [3]])
    #expect(w.focused == 1)
    var one = world([[1]], focused: 1)
    one.clearMonitor()
    #expect(lanes(one) == [[1]])
}
