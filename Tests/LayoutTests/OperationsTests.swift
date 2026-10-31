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

@Test func growFollowsTheLanesAxis() throws {
    for rows in [false, true] {
        var w = world([[1], [2]], focused: 1)
        w.monitors[0].rows = rows
        w.grow(by: 100)
        #expect(w.monitors[0].lanes[0].size > w.monitors[0].lanes[1].size, "rows: \(rows)")
    }
    #expect(try Command.parse("grow -50") == [.grow(-50)])
    #expect(Command.grow(50).description == "grow +50")
}

@Test func eachWindowGetsWhatItKeepsFromTheOnesWithRoomToGive() {
    var columns = world([[1], [2], [3]], focused: 1)
    columns.respect([2: CGSize(width: 500, height: 0), 3: CGSize(width: 400, height: 0)], inner: 0, outer: 0)
    let f = columns.frames(inner: 0, outer: 0)
    #expect(f[2]?.width == 500)
    #expect(f[3]?.width == 400)
    #expect(f[1]?.width == 100)

    var stack = world([[1, 2]], focused: 1)
    stack.respect([1: CGSize(width: 0, height: 500)], inner: 0, outer: 0)
    #expect(stack.frames(inner: 0, outer: 0)[1]?.height == 500)
    #expect(stack.frames(inner: 0, outer: 0)[2]?.height == 300)

    var rows = world([[1, 2], [3]], focused: 1)
    rows.monitors[0].rows = true
    rows.respect([1: CGSize(width: 700, height: 0), 3: CGSize(width: 0, height: 600)], inner: 0, outer: 0)
    #expect(rows.frames(inner: 0, outer: 0)[1]?.width == 700)
    #expect(rows.frames(inner: 0, outer: 0)[2]?.width == 300)
    #expect(rows.frames(inner: 0, outer: 0)[3]?.height == 600)

    // With gaps the windows still end up that size.
    var gaps = world([[1, 2]], focused: 1)
    gaps.respect([1: CGSize(width: 0, height: 500)], inner: 10, outer: 10)
    #expect(gaps.frames(inner: 10, outer: 10)[1]?.height == 500)

    // Nothing to do, or nothing that can be done: as it was.
    var fine = world([[1], [2]], focused: 1)
    fine.respect([1: CGSize(width: 300, height: 0)], inner: 0, outer: 0)
    #expect(fine == world([[1], [2]], focused: 1))
    var full = world([[1], [2]], focused: 1)
    full.respect([1: CGSize(width: 700, height: 0), 2: CGSize(width: 700, height: 0)], inner: 0, outer: 0)
    #expect(full == world([[1], [2]], focused: 1))
}

@Test func aResizeStopsAtWhatAWindowKeepsAndTheOtherOneStopsGrowing() {
    let keeps = [WindowID(1): CGSize(width: 0, height: 350)]
    var shrunk = world([[1, 2]], focused: 1)
    shrunk.grow(by: -200)
    shrunk.respect(keeps, inner: 0, outer: 0)
    #expect(shrunk.frames(inner: 0, outer: 0)[1]?.height == 350)
    #expect(shrunk.frames(inner: 0, outer: 0)[2]?.height == 450)

    var other = world([[1, 2]], focused: 2)
    other.grow(by: 200)
    other.respect(keeps, inner: 0, outer: 0)
    #expect(other.frames(inner: 0, outer: 0)[2]?.height == 450)
}

@Test func growGoesAlongTheSplitThereIs() {
    for rows in [false, true] {
        var w = world([[1, 2]], focused: 1)
        w.monitors[0].rows = rows
        w.grow(by: 100)
        let sizes = w.monitors[0].lanes[0].sizes
        #expect(sizes[0] > sizes[1], "rows: \(rows)")
    }
}

@Test func cycleWindowGoesRoundScreensThenFloating() throws {
    var w = world([[1, 2], [3]], [[5]], focused: 3)
    w.floating = [9]
    w.cycleWindow(1)
    #expect(w.focused == 5 && w.activeMonitor == 1)
    w.cycleWindow(1)
    #expect(w.focused == 9)
    w.cycleWindow(1)
    #expect(w.focused == 1)
    w.cycleWindow(-1)
    #expect(w.focused == 9)
    #expect(try Command.parse("focus prev") == [.cycleWindow(-1)])
    #expect(Command.cycleWindow(1).description == "focus next")
}

@Test func arrangePutsFocusedFirst() throws {
    var w = world([[1, 2], [3], [4]], focused: 3)
    w.monitors[0].lanes[0].accordion = true
    w.monitors[0].fullscreen = 3
    w.arrange(.halves)
    #expect(lanes(w) == [[3], [1, 2, 4]])
    #expect(w.monitors[0].lanes.allSatisfy { !$0.accordion } && w.monitors[0].fullscreen == nil)
    w.arrange(.grid)
    #expect(lanes(w) == [[3, 1], [2, 4]])
    w.arrange(.rows)
    #expect(lanes(w) == [[3], [1], [2], [4]] && w.monitors[0].rows)
    w.arrange(.columns)
    #expect(!w.monitors[0].rows)
    w = world([[1]], focused: 1)
    w.arrange(.halves)
    #expect(lanes(w) == [[1]])
    #expect(try Command.parse("grid") == [.arrange(.grid)])
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

@Test func unpluggedLanesTakeTheirNewScreensScale() {
    // Re-tiled lanes weigh in points; a moved one weighs 1.
    var w = world([[1], [2]], [[3]])
    w.monitors[0].lanes[0].size = 600
    w.monitors[0].lanes[1].size = 400
    w.setMonitors([left])
    let width = w.frames(inner: 0, outer: 0)[3]?.width ?? 0
    #expect(abs(width - 1000.0 / 3) < 1)
    w.setMonitors([left, right])
    #expect(w.frames(inner: 0, outer: 0)[3]?.width == 1000)
}

@Test func eachSetOfScreensKeepsItsArrangement() {
    var w = world([[1]], [[2], [3]])
    w.setMonitors([left])
    #expect(lanes(w) == [[1], [2], [3]])
    // Arranged anew on A alone, and 4 opened there.
    w.monitors[0].lanes = [[3], [1], [2], [4]].map { Lane($0) }
    w.setMonitors([left, right])
    #expect(lanes(w) == [[1], [4]])
    #expect(lanes(w, 1) == [[2], [3]])
    w.setMonitors([left])
    #expect(lanes(w) == [[3], [1], [2], [4]])
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

@Test func undoBringsBackTheEarlierLayoutForTheWindowsThereAreNow() {
    let before = world([[1], [2]], [[3]], focused: 2)
    var now = before
    now.focused = 1
    #expect(now.sameLayout(as: before))
    now.moveToMonitor(1)
    #expect(!now.sameLayout(as: before))
    now.remove(3)  // closed since
    now.insert(4)  // opened since
    let back = now.restoring(before)
    #expect(lanes(back) == [[1], [2]])
    #expect(lanes(back, 1) == [[4]])
    #expect(back.focused == 2)
}

@Test func newWindowsFindAnEmptyScreenAndPanelsTheLeastBusyOne() {
    var w = world([[1], [2]], [], focused: 1)
    #expect(w.emptyMonitor == 1)
    #expect(w.leastBusy(prefer: 0) == 1)
    w.monitors[1].lanes = [Lane([3])]
    #expect(w.emptyMonitor == nil)
    #expect(w.leastBusy(prefer: 0) == 1)
    w.monitors[1].lanes = [Lane([3]), Lane([4])]
    #expect(w.leastBusy(prefer: 1) == 1)  // a tie goes to the preferred screen
    #expect(world([], [[3]]).emptyMonitor == nil)  // the active screen is empty already
}
