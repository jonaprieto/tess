import Foundation

/// TypeSafe's Jev, used only with the config's `jev`: for the picker,
/// one Choice over the candidates (which one the typed text means)
/// and one Noul (whether any fits), in one request; for cmd-tab,
/// which part of each window title to show. The key is
/// TYPESAFE_API_KEY from tess's environment or, since launchd passes
/// none, the login shell's, kept in memory. What it sends is never
/// logged.
@MainActor
enum Jev {
  private static var key: String?
  private static var waiting: [@MainActor (String?) -> Void]?

  /// The key, read once; `done` runs on the main thread, with nil
  /// when there is none.
  static func withKey(_ done: @escaping @MainActor (String?) -> Void)
  {
    if let key { return done(key) }
    if let env = ProcessInfo.processInfo.environment[
      "TYPESAFE_API_KEY"], !env.isEmpty
    {
      key = env
      return done(env)
    }
    if waiting != nil { waiting?.append(done); return }
    waiting = [done]
    // An interactive login shell reads ~/.zshrc and the like; the
    // marker skips whatever they print on the way.
    let shell =
      ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    Proc.run(
      shell,
      [
        "-l", "-i", "-c",
        "printf '\\n__tess_key=%s\\n' \"$TYPESAFE_API_KEY\""
      ], timeout: 5
    ) { out in
      let line = out?.split(separator: "\n").last {
        $0.hasPrefix("__tess_key=")
      }
      let found = line.map {
        String($0.dropFirst("__tess_key=".count))
      }.flatMap { $0.isEmpty ? nil : $0 }
      if found == nil {
        Log.write(
          "jev: no TYPESAFE_API_KEY in the environment or the login shell"
        )
      }
      key = found
      let all = waiting ?? []
      waiting = nil
      all.forEach { $0(found) }
    }
  }

  /// Which of `candidates` the user means by `typed` (with the
  /// focused window for context, as "the other screen" depends on
  /// it): the index, its probability, and the probability that any
  /// candidate fits. nil on any failure; `done` runs on the main
  /// thread.
  static func pick(
    _ typed: String, focused: String?, candidates: [String],
    _ done:
      @escaping @MainActor @Sendable (
        (index: Int, p: Double, fits: Double)?
      ) -> Void
  ) {
    guard !candidates.isEmpty else { return done(nil) }
    let ids = candidates.indices.map { String(format: "c%03d", $0) }
    let state: [String: Any] = [
      "typed": typed, "focused_window": focused ?? "none",
      "candidates": Dictionary(
        uniqueKeysWithValues: zip(ids, candidates))
    ]
    let questions: [String: Any] = [
      "pick": [
        "type": "choice",
        "instructions":
          "The user typed `typed` into a launcher on their Mac to switch to a window, tab or app, or to run a command. Which of `candidates` do they most likely want?",
        "criteria": Dictionary(
          uniqueKeysWithValues: ids.map { ($0, NSNull()) })
      ],
      "fits": [
        "type": "noul",
        "instructions":
          "Does any of `candidates` match what the user wants by typing `typed`?"
      ]
    ]
    ask(state, questions, timeout: 3) { answers in
      let probabilities =
        (answers?["pick"] as? [String: Any])?["probabilities"]
        as? [String: Double]
      let fits =
        (answers?["fits"] as? [String: Any])?["noul"] as? Double
      guard let probabilities, let fits,
        let best = probabilities.max(by: { $0.value < $1.value }),
        let i = ids.firstIndex(of: best.key)
      else { return done(nil) }
      done((i, best.value, fits))
    }
  }

  /// For cmd-tab's cards: which of each title's `parts` (cut by code,
  /// the app's own name left out) best tells which window it is. One
  /// Choice per title, all in one request; `done` gets the picks by
  /// title, empty on any failure, on the main thread.
  static func titleParts(
    _ items: [(app: String, title: String, parts: [String])],
    _ done: @escaping @MainActor @Sendable ([String: String]) -> Void
  ) {
    let ids = items.indices.map { String(format: "w%03d", $0) }
    let state: [String: Any] = [
      "windows": Dictionary(
        uniqueKeysWithValues: zip(
          ids, items.map { ["app": $0.app, "title": $0.title] }))
    ]
    var questions: [String: Any] = [:]
    for (id, item) in zip(ids, items) {
      questions[id] = [
        "type": "choice",
        "instructions":
          "A window switcher shows the title `windows.\(id).title` of a `windows.\(id).app` window cut down to one of its parts, under the app's name. Which part best tells the user which window this is?",
        "criteria": Dictionary(
          uniqueKeysWithValues: item.parts.map { ($0, NSNull()) })
      ]
    }
    ask(state, questions, timeout: 5) { answers in
      var out: [String: String] = [:]
      for (id, item) in zip(ids, items) {
        if let c = (answers?[id] as? [String: Any])?["choice"]
          as? String, item.parts.contains(c)
        {
          out[item.title] = c
        }
      }
      done(out)
    }
  }

  /// One request to Jev: the answers by question id, nil on any
  /// failure; `done` runs on the main thread.
  private static func ask(
    _ state: [String: Any], _ questions: [String: Any],
    timeout: Double,
    _ done: @escaping @MainActor @Sendable ([String: Any]?) -> Void
  ) {
    withKey { key in
      guard let key else { return done(nil) }
      let body: [String: Any] = [
        "model": "jev-latest", "state": state, "questions": questions
      ]
      var req = URLRequest(
        url: URL(string: "https://api.typesafe.ai/v1/systemone")!,
        timeoutInterval: timeout)
      req.httpMethod = "POST"
      req.setValue(
        "Bearer \(key)", forHTTPHeaderField: "Authorization")
      req.setValue(
        "application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try? JSONSerialization.data(withJSONObject: body)
      URLSession.shared.dataTask(with: req) { data, response, _ in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.flatMap {
          try? JSONSerialization.jsonObject(with: $0)
            as? [String: Any]
        }
        // Handed over, not shared: nothing here reads it again.
        nonisolated(unsafe) let answers =
          json?["answers"] as? [String: Any]
        if answers == nil {
          Log.write("jev: no answer (HTTP \(status))")
        }
        DispatchQueue.main.async { done(answers) }
      }.resume()
    }
  }
}
