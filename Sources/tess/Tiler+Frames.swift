import AppKit
import Layout

/// Where windows go: what the layout asks for, and writing it.
extension Tiler {
  func scheduleApply() {
    guard !applyScheduled else { return }
    applyScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.applyScheduled = false
      self?.apply()
    }
  }


  /// Where each window goes: the layout's frames, with Zen's window
  /// filling its screen.
  var targets: [WindowID: CGRect] {
    var out = world.frames(inner: config.inner, outer: config.outer)
    // ponytail: Zen fills the screen here, not in the model, so
    // leaving it restores nothing and undo never sees it; a re-tile
    // during Zen reads the filled frame, as under fullscreen.
    if zenWorking, let f = world.focused, let p = world.locate(f) {
      out[f] = world.monitors[p.m].frame
    }
    return out
  }


  func apply() {
    defer {
      onLayout()
      refreshOverlays()
      refreshVeil()
    }
    guard !starting, !paused, !gliding else { return }
    // Nothing moves under the mouse, nor before a drag's drop is in
    // the layout.
    if NSEvent.pressedMouseButtons & 1 != 0 || drag != nil {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        [weak self] in self?.scheduleApply()
      }
      return
    }
    // Before any write, so the first one is the last: found out
    // afterwards, every window would move a second time.
    world.respect(
      windowMinimums, inner: config.inner, outer: config.outer)
    // Reduce Motion is a say on this too: the windows go straight
    // there.
    if world.reveal(inner: config.inner, outer: config.outer),
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      glide()
    {
      return
    }
    // A window still leaving macOS fullscreen cannot be moved yet.
    for (id, target) in targets
    where !offSpace.contains(id)
      && infos[id]?.nativeFullscreen != true
    {
      guard let info = infos[id], let worker = workers[info.pid]
      else { continue }
      if info.frame.isNear(target) {
        if !assumed.contains(id) {
          writes[id] = (target, 0)
          refused.remove(id)
        }
        continue
      }
      var w = writes[id] ?? (target, 0)
      let moveOnly = onlyMoves(id, from: info.frame, to: target)
      if w.target != target { w = (target, 0) }
      guard w.tries < 3 else {
        if refused.insert(id).inserted {
          Log.write(
            "window \(id) keeps its own size (\(info.frame), wanted \(target))"
          )
          Events.record(
            "frame.refused",
            describe(id).merging(["wanted": target.json]) { $1 })
          // Only about the window in use: one further back has
          // nothing to act on.
          if !makeRoom(id, keeps: info.frame, wanted: target),
            id == world.focused
          {
            toast(
              L(
                "\(appName(id)) did not accept its tile. Try enlarging it or floating the window."
              ), seconds: 5)
          }
        }
        continue
      }
      w.tries += 1
      writes[id] = w
      worker.setFrame(id, target, moveOnly: moveOnly)
      // Assume it lands; the next snapshot says otherwise if not.
      infos[id]?.frame = target
      assumed.insert(id)
      landing[id] = Date().addingTimeInterval(1.5)
    }
  }


  /// Whether going to `target` takes no resize: the window has that
  /// size, or was refused it and no one has wiped `writes` to have it
  /// asked again, as a ribbon's every move otherwise would.
  func onlyMoves(
    _ id: WindowID, from frame: CGRect, to target: CGRect
  ) -> Bool {
    frame.size == target.size
      || (refused.contains(id)
        && writes[id]?.target.size == target.size)
  }


  /// A ribbon scrolled: its windows slide there, moved only, in as
  /// many steps as each app keeps up with, since a step not yet taken
  /// gives way to the next. `apply` then writes where they go as
  /// ever, so a window that missed the end still gets there. False if
  /// there is no slide.
  func glide() -> Bool {
    let moves = targets.compactMap {
      id, to -> (
        id: WindowID, worker: AppWorker, from: CGPoint, to: CGPoint
      )? in
      guard let info = infos[id], let worker = workers[info.pid],
        !offSpace.contains(id),
        info.frame.size == to.size || refused.contains(id),
        !info.frame.isNear(to)
      else { return nil }
      return (id, worker, info.frame.origin, to.origin)
    }
    guard !moves.isEmpty else { return false }
    gliding = true
    refreshDecorations()
    let start = CFAbsoluteTimeGetCurrent()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(2))
    timer.setEventHandler { [weak self] in
      guard let self else { return timer.cancel() }
      let t = (CFAbsoluteTimeGetCurrent() - start) / Self.glideTime
      guard t < 1 else {
        timer.cancel()
        self.gliding = false
        self.apply()
        return
      }
      let eased = 1 - (1 - t) * (1 - t)
      for m in moves {
        let p = CGPoint(
          x: (m.from.x + (m.to.x - m.from.x) * eased).rounded(),
          y: (m.from.y + (m.to.y - m.from.y) * eased).rounded())
        m.worker.setFrame(
          m.id,
          CGRect(
            origin: p, size: self.infos[m.id]?.frame.size ?? .zero),
          moveOnly: true)
      }
    }
    timer.resume()
    return true
  }

  static let glideTime = 0.13


  /// A window kept a bigger size than its tile: that is now the
  /// minimum of its app's windows, and the layout makes room so its
  /// neighbors do not end up underneath. False if it could not.
  func makeRoom(_ id: WindowID, keeps frame: CGRect, wanted: CGRect)
    -> Bool
  {
    let size = CGSize(
      width: frame.width > wanted.width + 1 ? frame.width : 0,
      height: frame.height > wanted.height + 1 ? frame.height : 0)
    // What Zen or tess fullscreen asks of a window is not the
    // layout's to change.
    let was = world.frames(inner: config.inner, outer: config.outer)
    guard size != .zero, was[id] == wanted,
      let app = infos[id].flatMap({ bundle($0.pid) })
    else { return false }
    let known = minimums[app] ?? .zero
    minimums[app] = CGSize(
      width: max(known.width, size.width),
      height: max(known.height, size.height))
    world.respect(
      windowMinimums, inner: config.inner, outer: config.outer)
    guard
      world.frames(inner: config.inner, outer: config.outer) != was
    else { return false }
    scheduleApply()
    return true
  }
}
