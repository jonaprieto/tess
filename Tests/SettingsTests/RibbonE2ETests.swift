import AppKit
import Layout
import Testing
@testable import tess

private let bundles = [
  "com.apple.Chess", "com.apple.Dictionary", "com.apple.FontBook",
  "com.apple.weather"
]

@MainActor
private func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool
{
  let until = Date().addingTimeInterval(seconds)
  while Date() < until {
    if done() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return done()
}

private func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
  abs(a.x - b.x) <= 3 && abs(a.y - b.y) <= 3
}

private func near(_ a: CGSize, _ b: CGSize) -> Bool {
  abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
}

/// A ribbon of real windows, through what no model can answer for:
/// AX, the window server, what macOS clamps, how fast apps follow.
/// `make e2e` runs it, opening the apps and having the running tess
/// leave them alone. This Tiler knows only those apps and never asks
/// macOS for focus, so nothing in use is moved and the keyboard stays
/// where it is. No key or click is sent.
@MainActor
@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["RIBBON_E2E"] == "1"),
  .timeLimit(.minutes(2)))
func aRibbonOfRealWindows() async throws {
  _ = NSApplication.shared
  let tiler = Tiler()
  tiler.config.emptyScreens = false
  tiler.config.windowLabels = .off
  tiler.config.jev = false
  let screens = Screens.current()
  tiler.world.ribbons = true
  tiler.world.setMonitors(
    screens.map { (id: $0.id, frame: $0.frame) },
    main: screens.first(where: \.isMain)?.id)
  tiler.starting = false
  let apps = NSWorkspace.shared.runningApplications.filter { app in
    bundles.contains { $0 == app.bundleIdentifier }
  }
  try #require(apps.count == bundles.count, "make e2e opens the apps")
  apps.forEach(tiler.track)

  let (inner, outer) = (tiler.config.inner, tiler.config.outer)
  func truth() -> [WindowID: CGRect] {
    Dictionary(tiler.windowStack.map { ($0.id, $0.frame) }) { a, _ in
      a
    }
  }
  func parked() -> Set<WindowID> {
    tiler.world.parked(inner: inner, outer: outer)
  }
  func arrived() -> Bool {
    let real = truth()
    // An app may hold a window to a size of its own (Dictionary's has
    // a tallest): that is `refused`, a thing tess already lives with.
    // Where it goes is still tess's to say.
    return !tiler.gliding
      && tiler.targets.allSatisfy { id, target in
        real[id].map {
          near($0.origin, target.origin)
            && (tiler.refused.contains(id)
              || near($0.size, target.size))
        } ?? false
      }
  }
  func lanes() -> [WindowID] {
    tiler.world.monitors[tiler.world.activeMonitor].lanes.flatMap(
      \.windows)
  }
  func report(_ what: String) {
    let real = truth()
    print(
      "E2E \(what): "
        + lanes().map { id in
          let r = real[id] ?? .zero, t = tiler.targets[id] ?? .zero
          return
            "\(id) at \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)) wanted \(Int(t.minX)),\(Int(t.minY)) \(Int(t.width))x\(Int(t.height))"
        }.joined(separator: " | "))
  }

  // Opened one by one into the ribbon, through the same path as any
  // new window.
  let tiled = await wait(20) {
    tiler.world.tiled.count == bundles.count
  }
  print("E2E windows \(tiler.infos.mapValues { tiler.kind($0) })")
  try #require(tiled, "every app's window is tiled")
  tiler.apply()
  var there = await wait(5, arrived)
  report("opened")
  #expect(there, "the ribbon settles")
  let m = tiler.world.activeMonitor
  let area = tiler.world.tileArea(m, inner: inner, outer: outer)
  let screen = tiler.world.monitors[m].frame
  #expect(tiler.world.parkEdge(m) == .bottom)
  #expect(
    parked().count == bundles.count - 2, "two fit, the rest wait")

  // What parks stays parked, on screen, in reach: macOS has had its
  // say after a moment.
  try await Task.sleep(for: .seconds(1))
  there = await wait(1, arrived)
  report("a second later")
  #expect(there, "macOS leaves them where they went")
  let stack = tiler.windowStack
  for id in parked() {
    let r = try #require(
      truth()[id],
      "a parked window stays on screen as far as macOS goes")
    #expect(
      screen.intersection(r).height >= 30, "\(id) shows its title bar"
    )
    #expect(
      screen.intersection(r).width >= 100,
      "\(id) shows enough to click")
    #expect(
      tiler.visibleWindows(stack).contains(id), "\(id) has a letter")
  }
  #expect(tiler.rescue() == 0, "parked is not lost")

  // Along the ribbon and back, each step waiting for the window
  // server to show it.
  var steps: [Double] = []
  let order = lanes()
  for id in order.reversed() + order {
    let start = Date()
    tiler.world.focused = id
    tiler.apply()
    there = await wait(4, arrived)
    steps.append(Date().timeIntervalSince(start) * 1000)
    if !there { report("step to \(id)") }
    #expect(there, "\(id) comes into view")
    #expect(!parked().contains(id))
    if let r = truth()[id] {
      #expect(
        area.insetBy(dx: -3, dy: -3).contains(r),
        "\(id) is tiled, whole")
    }
  }
  let sorted = steps.sorted()
  print(
    "E2E steps \(steps.count): median \(Int(sorted[sorted.count / 2])) ms, worst \(Int(sorted.last ?? 0)) ms"
  )

  // The slide, asked for directly: with Reduce Motion on, `apply`
  // goes straight there.
  tiler.world.focused = order.last
  tiler.apply()
  _ = await wait(3, arrived)
  tiler.world.focused = order.first
  let mover = try #require(order.last)
  let from = try #require(truth()[mover]?.minY)
  tiler.world.reveal(inner: inner, outer: outer)
  #expect(tiler.glide(), "a scroll has windows to slide")
  var path: Set<CGFloat> = []
  there = await wait(3) {
    if let y = truth()[mover]?.minY { path.insert(y) }
    return arrived()
  }
  let inBetween = path.filter {
    abs($0 - from) > 3
      && abs($0 - (tiler.targets[mover]?.minY ?? 0)) > 3
  }
  print(
    "E2E slide: \(path.count) positions, \(inBetween.count) on the way, of \(mover) from \(Int(from))"
  )
  #expect(there, "a slide ends where it should")
  #expect(
    inBetween.count >= 2, "the window goes through places on its way")

  // Keys held down: nothing queues up behind them and all of it
  // lands.
  let hammer = Date()
  for i in 0..<40 {
    tiler.world.focused = order[i % order.count]
    tiler.scheduleApply()
    try await Task.sleep(for: .milliseconds(30))
  }
  there = await wait(3, arrived)
  print(
    "E2E held key: settled \(Int(Date().timeIntervalSince(hammer) * 1000 - 1200)) ms after the last step"
  )
  if !there { report("held key") }
  #expect(there, "it lands after a burst")

  // A click on a window on the strip, as macOS reports it.
  let clicked = try #require(parked().first)
  tiler.syncFocus(clicked)
  tiler.scheduleApply()
  there = await wait(3) { !parked().contains(clicked) && arrived() }
  #expect(there, "a clicked tab comes into view")

  // Grown, only its column changes; the others keep their size, and
  // even goes back.
  tiler.world.focused = order[0]
  tiler.apply()
  _ = await wait(3, arrived)
  let others = order.dropFirst().compactMap { truth()[$0]?.size }
  let width = truth()[order[0]]?.width ?? 0
  _ = tiler.run([.grow(200)], source: "e2e")
  there = await wait(3, arrived)
  #expect(there, "a grown column lands")
  #expect(abs((truth()[order[0]]?.width ?? 0) - width - 200) <= 6)
  #expect(
    order.dropFirst().compactMap { truth()[$0]?.size } == others,
    "the others keep their size")
  _ = tiler.run([.balance], source: "e2e")
  there = await wait(3, arrived)
  #expect(
    there && abs((truth()[order[0]]?.width ?? 0) - width) <= 3,
    "balance takes it back")

  // Moved along the ribbon, as a swap.
  tiler.world.move(.right)
  tiler.apply()
  there = await wait(3, arrived)
  #expect(
    there && lanes()[1] == order[0], "a move swaps and stays in view")

  // tess starting over finds every window by where it is, parked ones
  // included.
  let found = lanes().compactMap { id in
    truth()[id].map { (id: id, frame: $0) }
  }
  var restarted = World()
  restarted.ribbons = true
  restarted.setMonitors(
    screens.map { (id: $0.id, frame: $0.frame) },
    main: screens.first(where: \.isMain)?.id)
  restarted.activeMonitor = m
  restarted.rebuild(found, inner: inner, outer: outer)
  #expect(Set(restarted.tiled) == Set(order), "nobody is lost")
  #expect(
    restarted.monitors[m].lanes.count == order.count,
    "each its own column")
  restarted.focused = tiler.world.focused
  restarted.reveal(inner: inner, outer: outer)
  #expect(
    restarted.parked(inner: inner, outer: outer).count
      == parked().count)

  // An app quitting: the ribbon closes up, and scrolled to its end it
  // comes back.
  tiler.world.focused = order.last
  tiler.apply()
  _ = await wait(3, arrived)
  let last = try #require(lanes().last)
  let gone = try #require(
    apps.first { app in
      tiler.infos[last]?.pid == app.processIdentifier
    })
  gone.terminate()
  _ = await wait(5) { gone.isTerminated }
  tiler.untrack(gone.processIdentifier)
  tiler.apply()
  there = await wait(3, arrived)
  report("after quitting one")
  #expect(there, "the ribbon closes up")
  #expect(lanes().count == bundles.count - 1)

  // Off again: all of them tile side by side, on screen.
  _ = tiler.run([.ribbon], source: "e2e")
  tiler.apply()
  there = await wait(3, arrived)
  report("ribbon off")
  #expect(there, "off, they tile as ever")
  #expect(parked().isEmpty)
  for id in lanes() {
    if let r = truth()[id] {
      #expect(
        screen.intersection(r).height >= r.height - 3,
        "\(id) is on screen")
    }
  }

  print(
    "E2E kept their own size \(tiler.refused), minimums learned \(tiler.minimums)"
  )
  for worker in tiler.workers.values { worker.stop() }
}
