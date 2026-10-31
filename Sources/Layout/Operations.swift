import CoreGraphics

extension World {
    // MARK: Windows in and out

    /// A new window: a lane right of the focused lane on the active monitor, focused.
    public mutating func insert(_ id: WindowID) {
        guard !contains(id), monitors.indices.contains(activeMonitor) else { return }
        let m = activeMonitor
        let at = focusedPosition.flatMap { $0.m == m ? $0.l + 1 : nil } ?? monitors[m].lanes.count
        monitors[m].lanes.insert(newLane(id, on: m), at: at)
        focused = id
    }

    /// Focus goes to the next window in the stack, else the previous one, else the lane that
    /// took this lane's place, else the one before it, else the most recently focused window.
    public mutating func remove(_ id: WindowID) {
        let wasFocused = focused == id
        var next: WindowID?
        if floating.remove(id) == nil {
            guard let p = locate(id) else { return }
            let shared = monitors[p.m].lanes[p.l].windows.count > 1
            detach(id)
            let lanes = monitors[p.m].lanes
            if shared {
                let ws = lanes[p.l].windows
                next = ws[min(p.w, ws.count - 1)]
            } else if !lanes.isEmpty {
                next = pick(lanes[min(p.l, lanes.count - 1)].windows)
            }
        }
        mru.removeAll { $0 == id }
        if wasFocused { focused = next ?? mru.first(where: contains) }
        if focused == id { focused = nil }
    }

    public mutating func toggleFloating(_ id: WindowID) {
        if floating.contains(id) {
            floating.remove(id)
            insert(id)
        } else if detach(id) != nil {
            floating.insert(id)
        }
    }

    // MARK: Focus

    public mutating func focus(_ d: Direction) {
        guard let p = focusedPosition else {
            if let w = pick(monitors.indices.contains(activeMonitor) ? monitors[activeMonitor].windows : []) {
                focused = w
            } else {
                enter(neighbor(of: activeMonitor, d), from: d)
            }
            return
        }
        let mon = monitors[p.m]
        if mon.isMajor(d) {
            let t = p.l + d.sign
            if mon.lanes.indices.contains(t) { focused = pick(mon.lanes[t].windows); return }
        } else {
            let ws = mon.lanes[p.l].windows
            let t = p.w + d.sign
            if ws.indices.contains(t) { focused = ws[t]; return }
        }
        enter(neighbor(of: p.m, d), from: d)
    }

    public mutating func focusMonitor(_ n: Int) {
        guard monitors.indices.contains(n) else { return }
        activeMonitor = n
        focused = pick(monitors[n].windows)
    }

    public mutating func cycleMonitor(_ step: Int) {
        let c = monitors.count
        guard c > 0 else { return }
        focusMonitor(((activeMonitor + step) % c + c) % c)
    }

    /// The next window (`step` 1) or the previous one (-1), going through every screen's
    /// windows in order and then the floating ones, and round again.
    public mutating func cycleWindow(_ step: Int) {
        let all = tiled + floating.sorted()
        guard !all.isEmpty else { return }
        let i = focused.flatMap(all.firstIndex) ?? (step > 0 ? -1 : 0)
        focused = all[((i + step) % all.count + all.count) % all.count]
    }

    // MARK: Moving

    /// Along the lanes: pop out of a shared lane, else join the neighbor lane, else cross to
    /// the neighbor monitor. Along the stack: swap, else cross to the neighbor monitor.
    public mutating func move(_ d: Direction) {
        guard let id = focused, let p = locate(id) else { return }
        let mon = monitors[p.m]
        let lane = mon.lanes[p.l]
        if mon.isMajor(d) {
            if lane.windows.count > 1 {
                detach(id)
                monitors[p.m].lanes.insert(newLane(id, on: p.m), at: d.sign > 0 ? p.l + 1 : p.l)
            } else if mon.lanes.indices.contains(p.l + d.sign) {
                detach(id)
                append(id, toLane: d.sign > 0 ? p.l : p.l - 1, on: p.m)
            } else if let n = neighbor(of: p.m, d) {
                detach(id)
                place(id, on: n, from: d)
            }
        } else {
            let t = p.w + d.sign
            if lane.windows.indices.contains(t) {
                monitors[p.m].lanes[p.l].windows.swapAt(p.w, t)
                monitors[p.m].lanes[p.l].sizes.swapAt(p.w, t)
            } else if let n = neighbor(of: p.m, d) {
                detach(id)
                place(id, on: n, from: d)
            }
        }
        focused = id
    }

    /// The focused window goes to the right end of monitor `n`.
    public mutating func moveToMonitor(_ n: Int) {
        guard monitors.indices.contains(n), let id = focused, let p = locate(id), p.m != n else { return }
        detach(id)
        monitors[n].lanes.append(newLane(id, on: n))
        focused = id
    }

    // MARK: Sizes and modes

    /// `px` along a screen axis: the lane's size on the lanes' axis, else the window's size in its stack.
    public mutating func resize(_ axis: Axis, by px: Double) {
        guard let p = focusedPosition else { return }
        let mon = monitors[p.m]
        if mon.isMajor(axis) {
            let extent = mon.rows ? mon.frame.height : mon.frame.width
            let s = grown(mon.lanes.map(\.size), at: p.l, by: px, extent: extent)
            for i in s.indices { monitors[p.m].lanes[i].size = s[i] }
        } else {
            let extent = mon.rows ? mon.frame.width : mon.frame.height
            monitors[p.m].lanes[p.l].sizes = grown(mon.lanes[p.l].sizes, at: p.w, by: px, extent: extent)
        }
    }

    /// `px` along the split there is: wider in columns and taller in rows, or the other way
    /// for the windows stacked in a lone lane, which have no other lane to take room from.
    public mutating func grow(by px: Double) {
        guard let p = focusedPosition else { return }
        resize(monitors[p.m].rows != (monitors[p.m].lanes.count == 1) ? .height : .width, by: px)
    }

    public mutating func balance() {
        guard monitors.indices.contains(activeMonitor) else { return }
        for i in monitors[activeMonitor].lanes.indices {
            monitors[activeMonitor].lanes[i].size = 1
            monitors[activeMonitor].lanes[i].sizes = monitors[activeMonitor].lanes[i].sizes.map { _ in 1 }
        }
    }

    public mutating func flip() {
        guard monitors.indices.contains(activeMonitor) else { return }
        monitors[activeMonitor].rows.toggle()
    }

    public mutating func toggleAccordion() {
        guard let p = focusedPosition else { return }
        monitors[p.m].lanes[p.l].accordion.toggle()
    }

    public mutating func toggleFullscreen() {
        guard let id = focused, let p = locate(id) else { return }
        monitors[p.m].fullscreen = monitors[p.m].fullscreen == id ? nil : id
    }

    /// The active monitor's windows, focused first and the rest in order, as `a` with even
    /// sizes, no accordion and no fullscreen.
    public mutating func arrange(_ a: Arrangement) {
        guard monitors.indices.contains(activeMonitor) else { return }
        let all = monitors[activeMonitor].windows
        let ws = all.filter { $0 == focused } + all.filter { $0 != focused }
        let lanes: [[WindowID]] = switch a {
        case .halves: [Array(ws.prefix(1)), Array(ws.dropFirst())]
        case .columns, .rows: ws.map { [$0] }
        case .grid: [Array(ws.prefix((ws.count + 1) / 2)), Array(ws.dropFirst((ws.count + 1) / 2))]
        }
        monitors[activeMonitor].lanes = lanes.filter { !$0.isEmpty }.map { Lane($0) }
        monitors[activeMonitor].rows = a == .rows
        monitors[activeMonitor].fullscreen = nil
    }

    // MARK: Monitors

    /// The displays now attached, in monitor-number order. An unplugged monitor's lanes go to
    /// the right end of `main` (else the first monitor) and are remembered by display UUID;
    /// when that display comes back, its windows still alive go back to it. A set of displays
    /// seen before gets back the arrangement it was left in, as undo restores one.
    public mutating func setMonitors(_ infos: [(id: String, frame: CGRect)], main: String? = nil) {
        guard !infos.isEmpty else { return }  // displays flapping: keep the layout
        let old = monitors
        monitors = infos.map { info in
            guard var m = old.first(where: { $0.id == info.id }) else { return Monitor(id: info.id, frame: info.frame) }
            // A display rotated between landscape and portrait gets the lanes that fit it.
            if (m.frame.height > m.frame.width) != (info.frame.height > info.frame.width) {
                m.rows = info.frame.height > info.frame.width
            }
            m.frame = info.frame
            return m
        }
        let target = monitors.firstIndex { $0.id == main } ?? 0
        for gone in old where !monitors.contains(where: { $0.id == gone.id }) {
            parked[gone.id] = gone.lanes
            // Weights compare only within a screen: the lanes take this one's scale, or a lane
            // weighed 1 beside lanes weighed in points would be a sliver.
            let scale = (mean(monitors[target].lanes.map(\.size)) ?? 1) / (mean(gone.lanes.map(\.size)) ?? 1)
            monitors[target].lanes += gone.lanes.map { lane in
                var lane = lane
                lane.size *= scale
                return lane
            }
        }
        for i in monitors.indices where !old.contains(where: { $0.id == monitors[i].id }) {
            for var lane in parked.removeValue(forKey: monitors[i].id) ?? [] {
                let alive = lane.windows.indices.filter { locate(lane.windows[$0]) != nil }
                guard !alive.isEmpty else { continue }
                lane.windows = alive.map { lane.windows[$0] }
                lane.sizes = alive.map { lane.sizes[$0] }
                for id in lane.windows { detach(id) }
                monitors[i].lanes.append(lane)
            }
        }
        activeMonitor = focusedPosition?.m ?? min(activeMonitor, monitors.count - 1)
        let was = Set(old.map(\.id)), now = Set(monitors.map(\.id))
        guard was != now else { return }
        if !was.isEmpty { layouts[was] = old }
        guard let saved = layouts[now] else { return }
        var then = self
        then.monitors = saved
        for id in floating { then.detach(id) }  // floated since: stays floating
        self = restoring(then)
    }

    /// The nearest monitor whose center lies mostly in direction `d`.
    func neighbor(of m: Int, _ d: Direction) -> Int? {
        guard monitors.indices.contains(m) else { return nil }
        let c = monitors[m].frame
        func delta(_ i: Int) -> (dx: Double, dy: Double) {
            (monitors[i].frame.midX - c.midX, monitors[i].frame.midY - c.midY)
        }
        return monitors.indices.filter { i in
            guard i != m else { return false }
            let (dx, dy) = delta(i)
            switch d {
            case .left: return dx < 0 && abs(dx) >= abs(dy)
            case .right: return dx > 0 && abs(dx) >= abs(dy)
            case .up: return dy < 0 && abs(dy) > abs(dx)
            case .down: return dy > 0 && abs(dy) > abs(dx)
            }
        }.min { a, b in
            let (ax, ay) = delta(a), (bx, by) = delta(b)
            return ax * ax + ay * ay < bx * bx + by * by
        }
    }

    // MARK: Helpers

    /// Takes the window out of its lane (dropping the lane if it empties). Focus is untouched.
    @discardableResult
    mutating func detach(_ id: WindowID) -> Position? {
        guard let p = locate(id) else { return nil }
        monitors[p.m].lanes[p.l].windows.remove(at: p.w)
        monitors[p.m].lanes[p.l].sizes.remove(at: p.w)
        if monitors[p.m].lanes[p.l].windows.isEmpty { monitors[p.m].lanes.remove(at: p.l) }
        if monitors[p.m].fullscreen == id { monitors[p.m].fullscreen = nil }
        return p
    }

    /// Focus arrives on monitor `n` moving in `d`: the lane at the near edge, else the most recent window.
    mutating func enter(_ n: Int?, from d: Direction) {
        guard let n else { return }
        activeMonitor = n
        let mon = monitors[n]
        guard let first = mon.lanes.first, let last = mon.lanes.last else { focused = nil; return }
        focused = mon.isMajor(d) ? pick((d.sign > 0 ? first : last).windows) : pick(mon.windows)
    }

    /// A window arriving on monitor `n` moving in `d` gets its own lane at the near edge.
    mutating func place(_ id: WindowID, on n: Int, from d: Direction) {
        let lane = newLane(id, on: n)
        if monitors[n].isMajor(d) && d.sign > 0 {
            monitors[n].lanes.insert(lane, at: 0)
        } else {
            monitors[n].lanes.append(lane)
        }
    }

    mutating func append(_ id: WindowID, toLane l: Int, on m: Int) {
        monitors[m].lanes[l].sizes.append(mean(monitors[m].lanes[l].sizes) ?? 1)
        monitors[m].lanes[l].windows.append(id)
    }

    /// A lane as big as the average lane on monitor `m`.
    func newLane(_ id: WindowID, on m: Int) -> Lane {
        Lane([id], size: mean(monitors[m].lanes.map(\.size)) ?? 1)
    }
}

func mean(_ xs: [Double]) -> Double? {
    xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
}

/// Weights as shares of 1, with entry `i` grown by `px` out of `extent` (kept within 5-95%)
/// and the others scaled to fill the rest.
func grown(_ sizes: [Double], at i: Int, by px: Double, extent: Double) -> [Double] {
    guard sizes.count > 1, extent > 0 else { return sizes }
    let total = sizes.reduce(0, +)
    let share = min(max(sizes[i] / total + px / extent, 0.05), 0.95)
    let rest = total - sizes[i]
    return sizes.indices.map { j in
        if j == i { return share }
        return rest > 0 ? sizes[j] / rest * (1 - share) : (1 - share) / Double(sizes.count - 1)
    }
}

extension World {
    /// A monitor with no windows, for a new window, unless the active one is empty itself.
    public var emptyMonitor: Int? {
        guard monitors.indices.contains(activeMonitor), !monitors[activeMonitor].windows.isEmpty else { return nil }
        return monitors.indices.first { monitors[$0].windows.isEmpty }
    }

    /// The monitor with the fewest windows; `prefer` wins a tie.
    public func leastBusy(prefer: Int) -> Int {
        monitors.indices.min { a, b in
            (monitors[a].windows.count, a == prefer ? 0 : 1) < (monitors[b].windows.count, b == prefer ? 0 : 1)
        } ?? prefer
    }

    /// Every lane on the active monitor goes, in order, to the right end of the next monitor.
    public mutating func clearMonitor() {
        let m = activeMonitor
        guard monitors.count > 1, monitors.indices.contains(m) else { return }
        let next = (m + 1) % monitors.count
        monitors[next].lanes += monitors[m].lanes
        monitors[m].lanes = []
        monitors[m].fullscreen = nil
        if let f = focused { focused = f }
    }
}

extension World {
    // MARK: Undo

    /// Whether `other` arranges the windows the same way (focus aside).
    public func sameLayout(as other: World) -> Bool {
        monitors == other.monitors && floating == other.floating
    }

    /// The arrangement of `old`, an earlier copy, for the windows and screens there are now:
    /// windows closed since are left out, windows opened since go to the end of the screen they
    /// are on, and focus goes back to what `old` had focused.
    public func restoring(_ old: World) -> World {
        var w = old
        for id in w.tiled + Array(w.floating) where !contains(id) { w.remove(id) }
        w.parked = parked
        w.layouts = layouts
        w.setMonitors(monitors.map { (id: $0.id, frame: $0.frame) })
        for (m, mon) in monitors.enumerated() {
            for id in mon.windows where !w.contains(id) { w.place(id, .monitor(m)) }
        }
        for id in floating where !w.contains(id) { w.floating.insert(id) }
        if let f = old.focused, w.contains(f) { w.focused = f }
        return w
    }
}
