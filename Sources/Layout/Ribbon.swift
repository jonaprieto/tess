import CoreGraphics

/// Where a ribbon parks the windows out of view.
public enum ParkEdge: Equatable, Sendable {
  case bottom, left, right
}

/// A ribbon as the switcher and the menu bar draw it: its lanes in
/// order, how long each is on a screen of 1, and which are in view.
public struct Strip: Equatable, Sendable {
  public var monitor: Int
  public var lanes: [[WindowID]]
  public var lengths: [Double]
  public var shown: [Bool]
}

/// A ribbon: a screen whose columns keep their width and run on past
/// its edge, with the screen a window onto them. Windows out of view
/// are not hidden, which would strand them if tess stopped: they wait
/// on a strip of the screen, each still showing a part, so they can
/// be seen and clicked.
extension World {
  /// macOS keeps a window's title bar on screen, 32 to 52 points of
  /// it depending on the app, so parked along the bottom each is a
  /// tab with its title.
  public static let trayDepth = 52.0

  /// Sideways macOS lets a window go much further; this leaves enough
  /// to click.
  public static let sideDepth = 20.0

  /// Whether no other screen lies past this edge of screen `m`.
  private func isFree(_ m: Int, _ edge: ParkEdge) -> Bool {
    let f = monitors[m].frame
    return !monitors.indices.contains { i in
      let o = monitors[i].frame
      guard i != m else { return false }
      switch edge {
      case .bottom:
        return o.minY >= f.maxY - 1 && o.minX < f.maxX
          && o.maxX > f.minX
      case .right:
        return o.minX >= f.maxX - 1 && o.minY < f.maxY
          && o.maxY > f.minY
      case .left:
        return o.maxX <= f.minX + 1 && o.minY < f.maxY
          && o.maxY > f.minY
      }
    }
  }

  /// Bottom, unless a screen lies below: a window parked there would
  /// land on that screen, so a free side takes over.
  public func parkEdge(_ m: Int) -> ParkEdge {
    [.bottom, .right, .left].first { isFree(m, $0) } ?? .bottom
  }

  /// Where a screen's windows tile: its frame without the outer gap
  /// and, on a ribbon, without the strip the parked windows use. The
  /// strip stays there when nothing is parked: tiled windows would
  /// otherwise be resized each time one came or went.
  public func tileArea(_ m: Int, inner: Double, outer: Double)
    -> CGRect
  {
    let mon = monitors[m]
    var area = mon.frame.insetBy(dx: outer, dy: outer)
    guard mon.ribbon, !area.isNull else { return area }
    switch parkEdge(m) {
    case .bottom:
      area.size.height =
        mon.frame.maxY - Self.trayDepth - inner - area.minY
    case .right:
      area.size.width =
        mon.frame.maxX - Self.sideDepth - inner - area.minX
    case .left:
      let edge = mon.frame.minX + Self.sideDepth + inner
      area.size.width = area.maxX - edge
      area.origin.x = edge
    }
    return area
  }

  /// Each lane's start and length along the ribbon, from its first
  /// lane. A lone lane fills the screen; otherwise a `span` of 1/n
  /// fits n lanes exactly, the gaps between them included.
  func laneSpans(_ m: Int, whole: Double, inner: Double) -> [Span] {
    let lanes = monitors[m].lanes
    var at = 0.0
    return lanes.map { lane in
      let length = max(
        (lanes.count == 1 ? 1 : lane.span) * (whole + inner) - inner,
        1)
      let a = at.rounded(), b = (at + length).rounded()
      at += length + inner
      return Span(start: a, length: b - a)
    }
  }

  /// The `span` that gives a lane `length`.
  private func span(
    _ m: Int, of length: Double, inner: Double, outer: Double
  ) -> Double {
    let whole = along(m, tileArea(m, inner: inner, outer: outer))
      .length
    return ((length + inner) / (whole + inner)).clamped(0.1, 1)
  }

  private func along(_ m: Int, _ area: CGRect) -> (
    start: Double, length: Double
  ) {
    monitors[m].rows
      ? (area.minY, area.height) : (area.minX, area.width)
  }

  /// Whether a lane stays out on the ribbon. Wholly in view, always.
  /// Cut by the edge of the screen, if a fair part of it shows and it
  /// reaches no other screen and no strip: lanes of different widths
  /// seldom fill a screen exactly, and it would otherwise leave a
  /// hole.
  private func shown(_ m: Int, _ s: Span, whole: Double) -> Bool {
    let start = s.start - monitors[m].scroll, end = start + s.length
    guard start < -1 || end > whole + 1 else { return true }
    guard !monitors[m].rows,
      min(end, whole) - max(start, 0) >= s.length / 5
    else { return false }
    let past: ParkEdge = start < -1 ? .left : .right
    return parkEdge(m) != past && isFree(m, past)
  }

  /// Where a ribbon's windows go: lanes in view tile as ever, the
  /// rest park, the same size so that coming back only takes a move,
  /// keeping the ribbon's order.
  func ribbonFrames(_ m: Int, inner: Double, outer: Double)
    -> [WindowID: CGRect]
  {
    let mon = monitors[m]
    let area = tileArea(m, inner: inner, outer: outer)
    guard !area.isNull, area.width > 0, area.height > 0 else {
      return [:]
    }
    let (start, whole) = along(m, area)
    let across: (Double, Double) =
      mon.rows ? (area.minX, area.width) : (area.minY, area.height)
    func rect(_ a: Span, _ c: Span) -> CGRect {
      mon.rows
        ? CGRect(
          x: c.start, y: a.start, width: c.length, height: a.length)
        : CGRect(
          x: a.start, y: c.start, width: a.length, height: c.length)
    }
    var out: [WindowID: CGRect] = [:]
    var parked: [(id: WindowID, size: CGSize)] = []
    for (lane, s) in zip(
      mon.lanes, laneSpans(m, whole: whole, inner: inner))
    {
      let a = Span(
        start: start + s.start - mon.scroll, length: s.length)
      let places =
        lane.accordion
        ? lane.windows.map { _ in
          Span(start: across.0, length: across.1)
        }
        : split(across, lane.sizes, gap: inner)
      for (id, c) in zip(lane.windows, places) {
        if shown(m, s, whole: whole) {
          out[id] = rect(a, c)
        } else {
          parked.append((id, rect(a, c).size))
        }
      }
    }
    for (i, p) in parked.enumerated() {
      out[p.id] = parkFrame(
        m, area: area, index: i, of: parked.count, size: p.size)
    }
    return out
  }

  /// Window `index` of `count` on the screen's strip, spread out so
  /// each shows a part. Along the bottom they keep within the screen,
  /// so that their titles show and none reaches the one beside it;
  /// along a side, as tall as it is, they fan out past its bottom.
  /// One the size of the screen has no room to spread within it and
  /// fans out past the edge too, unless that is another screen.
  // ponytail: windows on a strip overlap and macOS decides which is
  // in front, so a screen-wide one can cover the rest; shrink parked
  // windows if that bites.
  private func parkFrame(
    _ m: Int, area: CGRect, index: Int, of count: Int, size: CGSize
  ) -> CGRect {
    let f = monitors[m].frame
    func spread(_ start: Double, _ room: Double) -> Double {
      (start + room * Double(index) / Double(max(count - 1, 1)))
        .rounded()
    }
    let edge = parkEdge(m)
    func fan(_ length: Double) -> Double {
      length * Double(count - 1) / Double(count)
    }
    guard edge != .bottom else {
      let inside = max(area.width - size.width, 0)
      let room =
        inside < 1 && isFree(m, .right) ? fan(area.width) : inside
      return CGRect(
        origin: CGPoint(
          x: spread(area.minX, room), y: f.maxY - Self.trayDepth),
        size: size)
    }
    let x =
      edge == .right
      ? f.maxX - Self.sideDepth : f.minX + Self.sideDepth - size.width
    let past = CGRect(
      x: x, y: f.maxY, width: size.width, height: size.height)
    let blocked = monitors.indices.contains {
      $0 != m && monitors[$0].frame.intersects(past)
    }
    let room =
      blocked ? max(area.height - size.height, 0) : fan(area.height)
    return CGRect(
      origin: CGPoint(x: x, y: spread(area.minY, room)), size: size)
  }

  /// Whether a frame is on screen `m`'s strip, where a ribbon parks:
  /// what a window out of view looks like to `rebuild`, which has
  /// only frames to go on.
  func onStrip(_ m: Int, _ r: CGRect) -> Bool {
    let f = monitors[m].frame
    guard monitors[m].ribbon else { return false }
    switch parkEdge(m) {
    case .bottom:
      return r.minY >= f.maxY - Self.trayDepth - 1 && r.minY < f.maxY
        && r.maxX > f.minX && r.minX < f.maxX
    case .right:
      return r.minX >= f.maxX - Self.sideDepth - 1 && r.minX < f.maxX
        && r.minY < f.maxY && r.maxY > f.minY
    case .left:
      return r.maxX <= f.minX + Self.sideDepth + 1 && r.maxX > f.minX
        && r.minY < f.maxY && r.maxY > f.minY
    }
  }

  /// `rebuild` read a ribbon's lanes off the screen: each gets the
  /// length it was found with, in the order the ribbon had, new ones
  /// last. `order` is that of its windows before. A lone lane fills
  /// the screen whatever its length, so that says nothing about it.
  mutating func keepRibbon(
    _ m: Int, order: [WindowID], lengths: [WindowID: Double],
    inner: Double, outer: Double
  ) {
    func rank(_ lane: Lane) -> Int {
      lane.windows.compactMap(order.firstIndex).min() ?? order.count
    }
    let lanes = monitors[m].lanes.enumerated().sorted {
      (rank($0.element), $0.offset) < (rank($1.element), $1.offset)
    }.map(\.element)
    monitors[m].lanes = lanes.map { lane in
      var lane = lane
      if lanes.count > 1,
        let length = lane.windows.compactMap({ lengths[$0] }).max()
      {
        lane.span = span(m, of: length, inner: inner, outer: outer)
      }
      return lane
    }
  }

  /// Scrolls each ribbon only as far as it takes to show the focused
  /// window's lane in full, and back from past its end. Whether
  /// anything moved.
  @discardableResult
  public mutating func reveal(inner: Double, outer: Double) -> Bool {
    var moved = false
    for m in monitors.indices where monitors[m].ribbon {
      let area = tileArea(m, inner: inner, outer: outer)
      guard !area.isNull else { continue }
      let (_, whole) = along(m, area)
      let spans = laneSpans(m, whole: whole, inner: inner)
      var scroll = monitors[m].scroll
      if let p = focusedPosition, p.m == m {
        let s = spans[p.l]
        if s.start + s.length - scroll > whole {
          scroll = s.start + s.length - whole
        }
        if s.start < scroll { scroll = s.start }
      }
      let end = spans.last.map { $0.start + $0.length } ?? 0
      scroll = max(min(scroll, end - whole), 0)
      if abs(scroll - monitors[m].scroll) > 0.5 { moved = true }
      monitors[m].scroll = scroll
    }
    return moved
  }

  /// The active screen becomes a ribbon, or stops being one.
  public mutating func toggleRibbon() {
    guard monitors.indices.contains(activeMonitor) else { return }
    setRibbon(activeMonitor, !monitors[activeMonitor].ribbon)
  }

  /// Lanes turning into a ribbon keep the share of the screen they
  /// have, so nothing jumps.
  public mutating func setRibbon(_ m: Int, _ on: Bool) {
    guard monitors[m].ribbon != on else { return }
    monitors[m].ribbon = on
    monitors[m].scroll = 0
    guard on else { return }
    let lanes = monitors[m].lanes
    let total = lanes.map(\.size).reduce(0, +)
    for i in lanes.indices {
      monitors[m].lanes[i].span =
        lanes.count > 1
        ? (lanes[i].size / total).clamped(0.1, 1) : 0.5
    }
  }

  /// Windows out of view on their ribbon: where they are is no sign
  /// that they are lost.
  public func parked(inner: Double, outer: Double) -> Set<WindowID> {
    Set(
      strips(inner: inner, outer: outer).flatMap { strip in
        zip(strip.lanes, strip.shown).filter { !$0.1 }.flatMap(\.0)
      })
  }

  /// Every ribbon, for drawing.
  public func strips(inner: Double, outer: Double) -> [Strip] {
    monitors.indices.filter { monitors[$0].ribbon }.compactMap { m in
      let area = tileArea(m, inner: inner, outer: outer)
      guard !area.isNull else { return nil }
      let (_, whole) = along(m, area)
      let spans = laneSpans(m, whole: whole, inner: inner)
      return Strip(
        monitor: m, lanes: monitors[m].lanes.map(\.windows),
        lengths: spans.map { $0.length / whole },
        shown: spans.map { shown(m, $0, whole: whole) })
    }
  }
}

extension Double {
  func clamped(_ low: Double, _ high: Double) -> Double {
    Swift.min(Swift.max(self, low), high)
  }
}
