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

    /// Where a window sits, to put another one there after it closes.
    public func slot(of id: WindowID) -> (position: Position, alone: Bool)? {
        guard let p = locate(id) else { return nil }
        return (p, monitors[p.m].lanes[p.l].windows.count == 1)
    }

    /// One letter per tiled window, by monitor, lane and stack, while letters last.
    public func labels(_ alphabet: String) -> [WindowID: Character] {
        Dictionary(uniqueKeysWithValues: zip(tiled, alphabet))
    }

    /// Out of the layout and the floating set, focus untouched.
    mutating func unplace(_ id: WindowID) {
        detach(id)
        floating.remove(id)
    }
}

/// Subsequence match of `query` in `text`, ignoring case; higher is better, nil if no match.
/// Consecutive letters and letters starting a word (or a camel-case hump) count extra.
public func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let q = query.lowercased().map(String.init)
    guard !q.isEmpty else { return 0 }
    let t = Array(text)
    var score = 0, qi = 0, last = -2
    for (i, c) in t.enumerated() where qi < q.count {
        guard String(c).lowercased() == q[qi] else { continue }
        score += 1
        if i == last + 1 { score += 3 }
        if i == 0 || !t[i - 1].isLetter || (c.isUppercase && t[i - 1].isLowercase) { score += 2 }
        last = i
        qi += 1
    }
    return qi == q.count ? score : nil
}
