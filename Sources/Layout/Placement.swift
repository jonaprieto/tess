import CoreGraphics

/// Where the picker puts a window.
public enum Spot: Equatable, Sendable {
    /// Take that window's place; it moves to the picked window's old place, or to a new lane
    /// right after when the picked window was not tiled.
    case replace(WindowID)
    /// A new lane right of that window.
    case beside(WindowID)
    /// A new lane right of the focused window.
    case here
    /// A new lane at the right end of that monitor (index from 0).
    case monitor(Int)
    /// The place a closed window left: its lane, or a lane of its own if it was alone.
    case slot(Position, alone: Bool)
    case float
}

/// Where a dragged window lands, relative to the window under the mouse.
public enum DropZone: Equatable, Sendable {
    /// A lane of its own before or after that window's lane (a split along the lanes).
    case lane(WindowID, after: Bool)
    /// In that window's lane, before or after it (a split across the lanes).
    case stack(WindowID, after: Bool)
    case swap(WindowID)
    /// The right end of that monitor.
    case screen(Int)
    /// Back where it was.
    case stay
}

extension World {
    /// Puts `id` (tiled, floating or new) at `spot` and focuses it.
    public mutating func place(_ id: WindowID, _ spot: Spot) {
        switch spot {
        case .replace(let t):
            guard t != id, let pt = locate(t) else { return }
            if locate(id) != nil {
                swap(id, t)
            } else {
                floating.remove(id)
                monitors[pt.m].lanes[pt.l].windows[pt.w] = id
                monitors[pt.m].lanes.insert(newLane(t, on: pt.m), at: pt.l + 1)
            }
        case .beside(let t):
            guard t != id, locate(t) != nil else { return }
            unplace(id)
            guard let pt = locate(t) else { return }
            monitors[pt.m].lanes.insert(newLane(id, on: pt.m), at: pt.l + 1)
        case .here:
            guard id != focused else { return }
            unplace(id)
            insert(id)
        case .monitor(let m):
            guard monitors.indices.contains(m) else { return }
            unplace(id)
            monitors[m].lanes.append(newLane(id, on: m))
        case .slot(let p, let alone):
            guard monitors.indices.contains(p.m) else { return }
            unplace(id)
            if alone || !monitors[p.m].lanes.indices.contains(p.l) {
                monitors[p.m].lanes.insert(newLane(id, on: p.m), at: min(p.l, monitors[p.m].lanes.count))
            } else {
                let w = min(p.w, monitors[p.m].lanes[p.l].windows.count)
                monitors[p.m].lanes[p.l].sizes.insert(mean(monitors[p.m].lanes[p.l].sizes) ?? 1, at: w)
                monitors[p.m].lanes[p.l].windows.insert(id, at: w)
            }
        case .float:
            detach(id)
            floating.insert(id)
        }
        focused = id
    }

    /// Exchanges the places of two tiled windows, on any monitors.
    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let pa = locate(a), let pb = locate(b) else { return }
        monitors[pa.m].lanes[pa.l].windows[pa.w] = b
        monitors[pb.m].lanes[pb.l].windows[pb.w] = a
    }

    /// Where tiled window `id` dragged to `point` would land (`frames`: where the layout puts
    /// each window; `front`: windows front to back, so of windows sharing a place, as in an
    /// accordion or under tess fullscreen, the one in front counts); nil off every screen. Over
    /// another window, or in the gap beside it: near an edge along the lanes, a lane of its own
    /// on that side; near an edge across them, that window's lane on that side; the middle,
    /// they swap. Over its own place, it stays. Over nothing on another screen, the right end of
    /// that screen.
    public func dropZone(_ id: WindowID, at point: CGPoint, frames: [WindowID: CGRect], front: [WindowID] = []) -> DropZone? {
        guard let from = locate(id) else { return nil }
        let others = frames.filter { $0.key != id && locate($0.key) != nil }
        func rank(_ w: WindowID) -> Int { front.firstIndex(of: w) ?? front.count }
        let over = others.filter { $0.value.contains(point) }.min { rank($0.key) < rank($1.key) }
        if over == nil, let own = frames[id], own.contains(point) { return .stay }
        func away(_ r: CGRect) -> Double { hypot(max(r.minX - point.x, 0, point.x - r.maxX), max(r.minY - point.y, 0, point.y - r.maxY)) }
        let near = others.filter { away($0.value) <= 12 }.min { (away($0.value), rank($0.key)) < (away($1.value), rank($1.key)) }
        guard let (t, f) = over ?? near else {
            guard let m = monitors.firstIndex(where: { $0.frame.contains(point) }) else { return nil }
            return m == from.m ? .stay : .screen(m)
        }
        let u = (point.x - f.minX) / f.width, v = (point.y - f.minY) / f.height
        if min(u, 1 - u, v, 1 - v) > 0.25 { return .swap(t) }
        let horizontal = min(u, 1 - u) <= min(v, 1 - v)
        let first = horizontal ? u < 0.5 : v < 0.5
        let rows = monitors[locate(t)!.m].rows
        return horizontal != rows ? .lane(t, after: !first) : .stack(t, after: !first)
    }

    /// `id` (tiled) moved to `zone` and focused.
    public mutating func drop(_ id: WindowID, _ zone: DropZone) {
        switch zone {
        case .stay:
            return
        case .swap(let t):
            swap(id, t)
        case .screen(let m):
            guard monitors.indices.contains(m) else { return }
            unplace(id)
            monitors[m].lanes.append(newLane(id, on: m))
        case .lane(let t, let after), .stack(let t, let after):
            guard t != id, locate(t) != nil else { return }
            unplace(id)
            let p = locate(t)!
            if case .lane = zone {
                monitors[p.m].lanes.insert(newLane(id, on: p.m), at: after ? p.l + 1 : p.l)
            } else {
                let w = after ? p.w + 1 : p.w
                monitors[p.m].lanes[p.l].sizes.insert(mean(monitors[p.m].lanes[p.l].sizes) ?? 1, at: w)
                monitors[p.m].lanes[p.l].windows.insert(id, at: w)
            }
        }
        focused = id
    }

    /// Where a window sits, to put another one there after it closes.
    public func slot(of id: WindowID) -> (position: Position, alone: Bool)? {
        guard let p = locate(id) else { return nil }
        return (p, monitors[p.m].lanes[p.l].windows.count == 1)
    }

    /// Out of the layout and the floating set, focus untouched.
    mutating func unplace(_ id: WindowID) {
        detach(id)
        floating.remove(id)
    }
}

/// `fuzzyScore` with the query's words in any order: "slack michael" finds "Michael - Slack".
/// Each word must match; the whole query in order scores as one when that is higher.
public func fuzzyWords(_ query: String, _ text: String) -> Int? {
    let words = query.split(whereSeparator: \.isWhitespace)
    guard words.count > 1 else { return fuzzyScore(query, text) }
    var sum = 0
    for w in words {
        guard let s = fuzzyScore(String(w), text) else { return fuzzyScore(query, text) }
        sum += s
    }
    return max(sum, fuzzyScore(query, text) ?? 0)
}

/// Subsequence match of `query` in `text`, ignoring case; higher is better, nil if no match.
/// Consecutive letters and letters starting a word (or a camel-case hump) count extra.
public func fuzzyScore(_ query: String, _ text: String) -> Int? {
    // Plain ASCII (nearly every title and URL): bytes, no allocation per character.
    if query.utf8.allSatisfy({ $0 < 128 }), text.utf8.allSatisfy({ $0 < 128 }) {
        return fuzzyASCII(Array(query.utf8), Array(text.utf8))
    }
    return fuzzy(query, text)?.score
}

/// The same scoring as `fuzzy`, on ASCII bytes.
func fuzzyASCII(_ query: [UInt8], _ text: [UInt8]) -> Int? {
    func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
    func letter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    guard !query.isEmpty else { return 0 }
    var score = 0, qi = 0, last = -2
    for i in text.indices where qi < query.count {
        let c = text[i]
        guard lower(c) == lower(query[qi]) else { continue }
        score += 1
        if i == last + 1 { score += 3 }
        if i == 0 || !letter(text[i - 1]) || (c >= 65 && c <= 90 && text[i - 1] >= 97 && text[i - 1] <= 122) { score += 2 }
        last = i
        qi += 1
    }
    return qi == query.count ? score : nil
}

/// Which characters of `text` the query matched (indices into `Array(text)`), for highlighting.
public func fuzzyPositions(_ query: String, _ text: String) -> [Int]? {
    fuzzy(query, text)?.positions
}

func fuzzy(_ query: String, _ text: String) -> (score: Int, positions: [Int])? {
    let q = query.lowercased().map(String.init)
    guard !q.isEmpty else { return (0, []) }
    let t = Array(text)
    var score = 0, qi = 0, last = -2
    var positions: [Int] = []
    for (i, c) in t.enumerated() where qi < q.count {
        guard String(c).lowercased() == q[qi] else { continue }
        score += 1
        if i == last + 1 { score += 3 }
        if i == 0 || !t[i - 1].isLetter || (c.isUppercase && t[i - 1].isLowercase) { score += 2 }
        positions.append(i)
        last = i
        qi += 1
    }
    return qi == q.count ? (score, positions) : nil
}
