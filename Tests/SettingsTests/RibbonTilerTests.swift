import AppKit
import Layout
import Testing
@testable import tess

// Off every real screen, so no overlay of these tests shows up over
// the windows in use.
private let screen = CGRect(
  x: 100_000, y: 100_000, width: 1800, height: 1129)

/// A tiler on a ribbon, each window a column, its frames those the
/// layout gives.
@MainActor
private func ribbon(_ ids: [WindowID], focused: WindowID) -> Tiler {
  _ = NSApplication.shared
  let tiler = Tiler()
  tiler.starting = false
  tiler.world.monitors = [Monitor(id: "A", frame: screen)]
  tiler.world.monitors[0].lanes = ids.map { Lane([$0]) }
  tiler.world.monitors[0].ribbon = true
  tiler.world.focused = focused
  tiler.world.reveal(
    inner: tiler.config.inner, outer: tiler.config.outer)
  for (id, frame) in tiler.world.frames(
    inner: tiler.config.inner, outer: tiler.config.outer)
  {
    tiler.infos[id] = WinInfo(
      id: id, pid: 1, frame: frame, title: "", standard: true,
      fullscreenButton: true, nativeFullscreen: false)
  }
  return tiler
}

private func parked(_ tiler: Tiler) -> Set<WindowID> {
  tiler.world.parked(
    inner: tiler.config.inner, outer: tiler.config.outer)
}

@MainActor
@Test func theRibbonCommandTurnsTheScreenIntoOneAndUndoTurnsItBack() {
  let tiler = ribbon([1, 2], focused: 1)
  tiler.world.monitors[0].ribbon = false
  _ = tiler.run([.ribbon], source: "test")
  #expect(tiler.world.monitors[0].ribbon)
  #expect(
    (tiler.layoutJSON()["screens"] as? [[String: Any]])?.first?[
      "ribbon"] as? Bool == true)
  #expect(tiler.tree().contains("ribbon"))
  _ = tiler.run([.undo], source: "test")
  #expect(!tiler.world.monitors[0].ribbon)
}

@MainActor
@Test func aPassOfTheLayoutGoesToTheFocusedWindow() {
  let tiler = ribbon([1, 2, 3, 4], focused: 1)
  #expect(parked(tiler) == [3, 4])
  tiler.world.focused = 4
  tiler.apply()
  #expect(parked(tiler) == [1, 2])
  #expect(tiler.world.monitors[0].scroll > 0)
}

@MainActor
@Test func aWindowClickedOnTheStripComesIntoView() {
  let tiler = ribbon([1, 2, 3, 4], focused: 1)
  tiler.syncFocus(3)
  tiler.apply()
  #expect(tiler.world.focused == 3)
  #expect(!parked(tiler).contains(3))
}

@MainActor
@Test
func windowsFoundLaterJoinTheEndOfTheRibbonInsteadOfReorderingIt() {
  let tiler = ribbon([1, 2, 3, 4], focused: 2)
  let f = CGRect(
    x: screen.minX + 200, y: screen.minY + 100, width: 600,
    height: 500)
  tiler.adopt([
    WinInfo(
      id: 5, pid: 1, frame: f, title: "", standard: true,
      fullscreenButton: true, nativeFullscreen: false)
  ])
  #expect(
    tiler.world.monitors[0].lanes.map(\.windows) == [
      [1], [2], [3], [4], [5]
    ])
}

@MainActor
@Test
func
  aWindowFoundOnAnotherScreenGoesWhereItIsAndTheRibbonStaysAsItWas()
{
  let tiler = ribbon([1, 2, 3], focused: 1)
  tiler.world.monitors[0].lanes = [Lane([1, 2]), Lane([3]), Lane([4])]
  let plain = CGRect(
    x: screen.maxX, y: screen.minY, width: 1800, height: 1000)
  tiler.world.monitors.append(Monitor(id: "B", frame: plain))
  tiler.world.monitors[1].lanes = [Lane([5])]
  tiler.world.reveal(
    inner: tiler.config.inner, outer: tiler.config.outer)
  let was = tiler.world.monitors[0]
  let right = CGRect(
    x: plain.minX + 900, y: plain.minY + 10, width: 880, height: 980)
  tiler.adopt([
    WinInfo(
      id: 6, pid: 1, frame: right, title: "", standard: true,
      fullscreenButton: true, nativeFullscreen: false)
  ])
  #expect(tiler.world.monitors[0] == was)
  #expect(Set(tiler.world.monitors[1].windows) == [5, 6])
  #expect(tiler.world.monitors[1].lanes.count == 2)
}

@MainActor
@Test func aRefusedSizeIsNotAskedForAgainUntilSomeoneSaysSo() {
  let tiler = ribbon([1, 2], focused: 1)
  let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
  let there = CGRect(x: 40, y: 0, width: 800, height: 1000)
  #expect(
    tiler.onlyMoves(1, from: frame, to: frame.offsetBy(dx: 40, dy: 0))
  )
  #expect(!tiler.onlyMoves(1, from: frame, to: there))
  tiler.refused.insert(1)
  tiler.writes[1] = (there, 3)
  #expect(
    tiler.onlyMoves(1, from: frame, to: there.offsetBy(dx: 40, dy: 0))
  )
  // A different size, or `writes` wiped by a sweep, an undo or new
  // screens: it gets asked.
  #expect(
    !tiler.onlyMoves(
      1, from: frame,
      to: CGRect(x: 40, y: 0, width: 700, height: 1000)))
  tiler.writes[1] = nil
  #expect(!tiler.onlyMoves(1, from: frame, to: there))
}

@MainActor
@Test func rescueLeavesParkedWindowsWhereTheyAre() {
  let tiler = ribbon([1, 2, 3, 4], focused: 1)
  #expect(tiler.rescue() == 0)
  // One that really is lost still comes back.
  tiler.infos[1]?.frame = CGRect(
    x: -9000, y: -9000, width: 800, height: 600)
  #expect(tiler.rescue() == 1)
}

@MainActor
@Test func parkedWindowsKeepTheirLettersEvenBehindEachOther() {
  let tiler = ribbon([1, 2, 3, 4, 5, 6], focused: 1)
  let frames = tiler.world.frames(
    inner: tiler.config.inner, outer: tiler.config.outer)
  let front = [WindowID(6), 5, 4, 3, 2, 1].map {
    (id: $0, frame: frames[$0]!)
  }
  #expect(Set(tiler.visibleWindows(front)) == [1, 2, 3, 4, 5, 6])
}

@MainActor
@Test func thePickerMapShowsEveryColumnSideBySide() {
  let tiler = ribbon([1, 2, 3, 4], focused: 1)
  let map = tiler.pickerMap()
  #expect(Set(map.windows.map(\.id)) == [1, 2, 3, 4])
  let xs = map.windows.map(\.frame.minX)
  #expect(Set(xs).count == 4)
  #expect(map.windows.allSatisfy { screen.contains($0.frame) })
}

@MainActor
@Test func nothingWaitsForASlideWhenThereIsNoWindowToMove() {
  let tiler = ribbon([1, 2, 3, 4], focused: 1)
  #expect(!tiler.glide())
  #expect(!tiler.gliding)
}
