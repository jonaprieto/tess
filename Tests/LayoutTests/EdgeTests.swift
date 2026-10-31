import CoreGraphics
import Foundation
import Testing
@testable import Layout

@Test func aStackOnARibbonKeepsTheLengthOfItsLongestWindow() {
  var w = World()
  w.setMonitors([
    (id: "A", frame: CGRect(x: 0, y: 40, width: 1800, height: 1129))
  ])
  w.monitors[0].lanes = [Lane([1, 2]), Lane([3])]
  w.monitors[0].ribbon = true
  w.keepRibbon(
    0, order: [1, 2, 3], lengths: [1: 500, 2: 900, 3: 500],
    inner: 10, outer: 10)
  #expect(w.monitors[0].lanes[0].span > w.monitors[0].lanes[1].span)
}

@Test func windowsOverlappingMostOfTheSmallerOneBecomeAnAccordion() {
  for (y1, h1, y2, h2) in [
    (100.0, 200.0, 150.0, 400.0), (100.0, 400.0, 350.0, 200.0)
  ] {
    var w = world([])
    w.rebuild([
      (id: 1, frame: CGRect(x: 10, y: y1, width: 980, height: h1)),
      (id: 2, frame: CGRect(x: 10, y: y2, width: 980, height: h2))
    ])
    #expect(w.monitors[0].lanes[0].accordion)
  }
}

@Test func aDisplayTurningSquareKeepsItsRows() {
  var w = world([])
  w.monitors[0].rows = true
  w.setMonitors([
    (
      id: w.monitors[0].id,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)
    )
  ])
  #expect(w.monitors[0].rows)
}

@Test func growingAgainstNoExtentChangesNothing() {
  #expect(grown([1, 1], at: 0, by: 10, extent: 0) == [1, 1])
}

@Test func aWindowShownEquallyOnTwoScreensGoesToTheFirst() {
  var w = World()
  w.setMonitors([
    (id: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
    (id: "B", frame: CGRect(x: 1100, y: 0, width: 1000, height: 800))
  ])
  #expect(
    w.monitorIndex(
      for: CGRect(x: 900, y: 100, width: 300, height: 400))
      == 0)
}

@Test func aWindowExactlyAtTheTopOfTheTrayCountsAsOnIt() {
  var w = World()
  w.setMonitors([
    (id: "A", frame: CGRect(x: 0, y: 40, width: 1800, height: 1129))
  ])
  w.monitors[0].ribbon = true
  let top = w.monitors[0].frame.maxY - World.trayDepth - 1
  #expect(
    w.onStrip(0, CGRect(x: 100, y: top, width: 400, height: 300)))
  #expect(
    !w.onStrip(0, CGRect(x: 100, y: top - 1, width: 400, height: 300))
  )
}
