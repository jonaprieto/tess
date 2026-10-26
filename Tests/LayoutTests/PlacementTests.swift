import CoreGraphics
import Testing
@testable import Layout

@Test func replaceSwapsTwoTiledWindows() {
    var w = world([[1, 2], [3]], [[4]], focused: 1)
    w.place(4, .replace(2))
    #expect(lanes(w) == [[1, 4], [3]])
    #expect(lanes(w, 1) == [[2]])
    #expect(w.focused == 4)
}

@Test func replaceWithANewWindowPushesTheOtherRight() {
    var w = world([[1, 2], [3]], focused: 1)
    w.place(9, .replace(2))
    #expect(lanes(w) == [[1, 9], [2], [3]])
    #expect(w.focused == 9)
    w.floating.insert(8)
    w.place(8, .replace(3))
    #expect(lanes(w) == [[1, 9], [2], [8], [3]])
    #expect(w.floating.isEmpty)
}

@Test func besideMakesANewLaneRightOfTheTarget() {
    var w = world([[1], [2, 3]], [[4]], focused: 1)
    w.place(4, .beside(2))
    #expect(lanes(w) == [[1], [2, 3], [4]])
    #expect(lanes(w, 1).isEmpty)
    w.place(1, .beside(3))
    #expect(lanes(w) == [[2, 3], [1], [4]])
    w.place(3, .beside(3))
    #expect(lanes(w) == [[2, 3], [1], [4]])
}

@Test func hereGoesNextToTheFocusedWindow() {
    var w = world([[1], [2]], [[4]], focused: 1)
    w.place(4, .here)
    #expect(lanes(w) == [[1], [4], [2]])
    #expect(w.focused == 4)
    w.focused = 1
    w.place(1, .here)
    #expect(lanes(w) == [[1], [4], [2]])
}

@Test func monitorAppendsAtTheRightEnd() {
    var w = world([[1], [2]], [[4]], focused: 1)
    w.place(1, .monitor(1))
    #expect(lanes(w) == [[2]])
    #expect(lanes(w, 1) == [[4], [1]])
    #expect(w.activeMonitor == 1)
    w.place(7, .monitor(5))
    #expect(!w.contains(7))
}

@Test func slotFillsTheGapOfAClosedWindow() {
    var w = world([[1], [2, 3, 4]], focused: 3)
    let s = w.slot(of: 3)!
    w.remove(3)
    w.place(9, .slot(s.position, alone: s.alone))
    #expect(lanes(w) == [[1], [2, 9, 4]])

    w = world([[1], [2], [3]], focused: 2)
    let t = w.slot(of: 2)!
    #expect(t.alone)
    w.remove(2)
    w.place(9, .slot(t.position, alone: t.alone))
    #expect(lanes(w) == [[1], [9], [3]])
}

@Test func floatTakesAWindowOutOfTheLayout() {
    var w = world([[1], [2]], focused: 2)
    w.place(2, .float)
    #expect(lanes(w) == [[1]])
    #expect(w.floating == [2])
}

@Test func labelsFollowMonitorsLanesAndStacks() {
    let w = world([[1, 2], [3]], [[4]])
    let l = stableLabels([:], windows: w.tiled, alphabet: "asd")
    #expect(l == [1: "a", 2: "s", 3: "d"])
}

@Test func fuzzyMatchesSubsequencesBestFirst() {
    #expect(fuzzyScore("brv", "Brave Browser") != nil)
    #expect(fuzzyScore("xyz", "Brave Browser") == nil)
    #expect(fuzzyScore("", "anything") == 0)
    let github = fuzzyScore("gh", "GitHub")!
    let gather = fuzzyScore("gh", "gather")!
    #expect(github > gather)
    #expect(fuzzyScore("cal", "Calendar")! > fuzzyScore("cal", "Musical")!)
}

@Test func fuzzyPositionsMarkTheMatchedCharacters() {
    #expect(fuzzyPositions("cal", "Calendar") == [0, 1, 2])
    #expect(fuzzyPositions("gh", "GitHub") == [0, 3])
    #expect(fuzzyPositions("zz", "GitHub") == nil)
    #expect(fuzzyPositions("", "GitHub") == [])
}

@Test func asciiFastPathScoresLikeTheGeneralOne() {
    let texts = ["GitHub", "gather", "Calendar", "Musical", "Brave Browser", "anoma-log", "pull/42 · github.com", "x"]
    for q in ["gh", "cal", "brv", "an", "pg", "zz", ""] {
        for t in texts {
            #expect(fuzzyScore(q, t) == fuzzy(q, t)?.score, "\(q) in \(t)")
        }
    }
}

@Test func dropZonesSplitAlongOrAcrossTheLanes() {
    // Lanes [1][2] on A (columns, 500 wide), nothing on B.
    var w = world([[1], [2]], [], focused: 2)
    let f = w.frames(inner: 0, outer: 0)
    func zone(_ x: Double, _ y: Double) -> DropZone? { w.dropZone(2, at: CGPoint(x: x, y: y), frames: f)?.zone }
    #expect(zone(20, 400) == .lane(1, after: false))
    #expect(zone(480, 400) == .lane(1, after: true))
    #expect(zone(250, 20) == .stack(1, after: false))
    #expect(zone(250, 780) == .stack(1, after: true))
    #expect(zone(250, 400) == .swap(1))
    #expect(zone(750, 400) == nil)  // over itself
    #expect(zone(1500, 400) == .screen(1))
    #expect(w.dropZone(2, at: CGPoint(x: 250, y: 780), frames: f)?.rect == CGRect(x: 0, y: 400, width: 500, height: 400))
    w.drop(2, .stack(1, after: true))
    #expect(lanes(w) == [[1, 2]] && w.focused == 2)
    w.drop(2, .lane(1, after: false))
    #expect(lanes(w) == [[2], [1]])
    w.drop(2, .swap(1))
    #expect(lanes(w) == [[1], [2]])
    w.drop(2, .screen(1))
    #expect(lanes(w) == [[1]] && lanes(w, 1) == [[2]])
    // Rows: top and bottom edges split along the lanes.
    w.monitors[0].rows = true
    w.monitors[0].lanes = [Lane([1]), Lane([3])]
    let g = w.frames(inner: 0, outer: 0)
    #expect(w.dropZone(3, at: CGPoint(x: 500, y: 10), frames: g)?.zone == .lane(1, after: false))
    #expect(w.dropZone(3, at: CGPoint(x: 10, y: 200), frames: g)?.zone == .stack(1, after: false))
}
