import CoreGraphics

extension World {
  /// Where every tiled window goes: each monitor's frame inset by
  /// `outer`, lanes and stacks split by weight with `inner` between
  /// them, on whole points.
  public func frames(inner: Double, outer: Double) -> [WindowID:
    CGRect]
  {
    var out: [WindowID: CGRect] = [:]
    for mon in monitors {
      let area = mon.frame.insetBy(dx: outer, dy: outer)
      guard !area.isNull, area.width > 0, area.height > 0 else {
        continue
      }
      let along: (Double, Double) =
        mon.rows ? (area.minY, area.height) : (area.minX, area.width)
      let across: (Double, Double) =
        mon.rows ? (area.minX, area.width) : (area.minY, area.height)
      func rect(_ a: Span, _ c: Span) -> CGRect {
        mon.rows
          ? CGRect(
            x: c.start, y: a.start, width: c.length, height: a.length)
          : CGRect(
            x: a.start, y: c.start, width: a.length, height: c.length)
      }
      for (lane, a) in zip(
        mon.lanes, split(along, mon.lanes.map(\.size), gap: inner))
      {
        if lane.accordion {
          for id in lane.windows {
            out[id] = rect(a, Span(start: across.0, length: across.1))
          }
        } else {
          for (id, c) in zip(
            lane.windows, split(across, lane.sizes, gap: inner))
          { out[id] = rect(a, c) }
        }
      }
      // Edge to edge, so it differs from a lone window, which already
      // fills the gaps.
      if let fs = mon.fullscreen, out[fs] != nil {
        out[fs] = mon.frame
      }
    }
    return out
  }

  /// Tiles `windows` by where they are now: each goes to the monitor
  /// holding its center, a lane is the windows whose range on the
  /// lanes' axis overlaps its first window's by half or more, and
  /// weights are the current sizes. A window off every screen gets a
  /// lane at the end of the active monitor. A window covering its
  /// monitor edge to edge, which only tess fullscreen does, is
  /// fullscreen again, its lane at the right end (so a restart keeps
  /// it). Accordion is not recovered.
  public mutating func rebuild(
    _ windows: [(id: WindowID, frame: CGRect)]
  ) {
    guard !monitors.isEmpty else { return }
    let full = monitors.compactMap(\.fullscreen)
    for i in monitors.indices {
      monitors[i].lanes = []
      monitors[i].fullscreen = nil
    }
    defer {
      for id in full {
        if let p = locate(id) { monitors[p.m].fullscreen = id }
      }
    }
    var lost: [WindowID] = []
    var byMonitor = Array(
      repeating: [(id: WindowID, frame: CGRect)](),
      count: monitors.count)
    var edgeToEdge: [(id: WindowID, m: Int)] = []
    for w in windows {
      floating.remove(w.id)
      if let m = monitors.firstIndex(where: {
        $0.frame.isNear(w.frame)
      }) {
        edgeToEdge.append((w.id, m))
      } else if let m = monitorIndex(for: w.frame) {
        byMonitor[m].append(w)
      } else {
        lost.append(w.id)
      }
    }
    for m in monitors.indices {
      let rows = monitors[m].rows
      func range(_ r: CGRect) -> (lo: Double, hi: Double) {
        rows ? (r.minY, r.maxY) : (r.minX, r.maxX)
      }
      var groups:
        [(
          lo: Double, hi: Double,
          members: [(id: WindowID, frame: CGRect)]
        )] = []
      for w in byMonitor[m].sorted(by: {
        (range($0.frame).lo, $0.id) < (range($1.frame).lo, $1.id)
      }) {
        let (lo, hi) = range(w.frame)
        func overlap(_ g: Int) -> Double {
          min(hi, groups[g].hi) - max(lo, groups[g].lo)
        }
        // Same lane only when the ranges mostly agree: a full-width
        // window left over from another layout must not swallow
        // everything that overlaps it.
        if let g = groups.indices.filter({
          overlap($0) >= 0.5
            * max(hi - lo, groups[$0].hi - groups[$0].lo)
        })
        .max(by: { overlap($0) < overlap($1) }) {
          groups[g].members.append(w)
        } else {
          groups.append((lo, hi, [w]))
        }
      }
      monitors[m].lanes = groups.map { g in
        let stack = g.members.sorted {
          (rows ? $0.frame.minX : $0.frame.minY, $0.id) < (
            rows ? $1.frame.minX : $1.frame.minY, $1.id
          )
        }
        func span(_ r: CGRect) -> (lo: Double, hi: Double) {
          rows ? (r.minX, r.maxX) : (r.minY, r.maxY)
        }
        // Windows lying on top of each other (left maximized, or by
        // another tiler's accordion) were not a stack: keep them full
        // size, one in front.
        let piled = zip(stack, stack.dropFirst()).contains { a, b in
          let (alo, ahi) = span(a.frame), (blo, bhi) = span(b.frame)
          return min(ahi, bhi) - max(alo, blo) > 0.5
            * min(ahi - alo, bhi - blo)
        }
        var lane = Lane(
          stack.map(\.id), size: g.hi - g.lo,
          sizes: piled
            ? nil
            : stack.map { rows ? $0.frame.width : $0.frame.height })
        lane.accordion = piled
        return lane
      }
    }
    let m = min(activeMonitor, monitors.count - 1)
    for id in lost { monitors[m].lanes.append(newLane(id, on: m)) }
    for (id, m) in edgeToEdge {
      monitors[m].lanes.append(newLane(id, on: m))
      // Alone on its monitor with no outer gap it is just a lone
      // window.
      if !byMonitor[m].isEmpty,
        !full.contains(where: { locate($0)?.m == m })
      {
        monitors[m].fullscreen = id
      }
    }
    if let f = focused { focused = f }
  }

  /// The monitor holding the frame's center, else the one showing at
  /// least a tenth of it.
  public func monitorIndex(for r: CGRect) -> Int? {
    let c = CGPoint(x: r.midX, y: r.midY)
    if let i = monitors.firstIndex(where: { $0.frame.contains(c) }) {
      return i
    }
    func shown(_ i: Int) -> Double {
      let x = monitors[i].frame.intersection(r)
      return x.isNull ? 0 : x.width * x.height
    }
    guard
      let best = monitors.indices.max(by: { shown($0) < shown($1) }),
      shown(best) >= 0.1 * r.width * r.height, r.width * r.height > 0
    else { return nil }
    return best
  }
}

struct Span {
  var start: Double, length: Double
}

/// `(start, length)` cut into parts weighted by `weights`, `gap`
/// apart, edges on whole points.
func split(
  _ whole: (Double, Double), _ weights: [Double], gap: Double
) -> [Span] {
  guard !weights.isEmpty else { return [] }
  let total = weights.reduce(0, +)
  let avail = max(whole.1 - gap * Double(weights.count - 1), 0)
  var pos = whole.0
  return weights.map { w in
    let len = avail * w / total
    let a = pos.rounded(), b = (pos + len).rounded()
    pos += len + gap
    return Span(start: a, length: b - a)
  }
}
