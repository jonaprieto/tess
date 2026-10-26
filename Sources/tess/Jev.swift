import Foundation

/// TypeSafe's Jev for the picker: one Choice over the candidates (which one the typed text
/// means) and one Noul (whether any fits), in one request. Used only with the config's `jev`.
/// The key is TYPESAFE_API_KEY from tess's environment or, since launchd passes none, the
/// login shell's, kept in memory. What it sends is never logged.
enum Jev {
    nonisolated(unsafe) private static var key: String?
    nonisolated(unsafe) private static var waiting: [(String?) -> Void]?

    /// The key, read once; `done` runs on the main thread, with nil when there is none.
    static func withKey(_ done: @escaping (String?) -> Void) {
        if let key { return done(key) }
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty {
            key = env
            return done(env)
        }
        if waiting != nil { waiting?.append(done); return }
        waiting = [done]
        // An interactive login shell reads ~/.zshrc and the like; the marker skips whatever
        // they print on the way.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        Proc.run(shell, ["-l", "-i", "-c", "printf '\\n__tess_key=%s\\n' \"$TYPESAFE_API_KEY\""], timeout: 5) { out in
            let line = out?.split(separator: "\n").last { $0.hasPrefix("__tess_key=") }
            let found = line.map { String($0.dropFirst("__tess_key=".count)) }.flatMap { $0.isEmpty ? nil : $0 }
            if found == nil { Log.write("jev: no TYPESAFE_API_KEY in the environment or the login shell") }
            key = found
            let all = waiting ?? []
            waiting = nil
            all.forEach { $0(found) }
        }
    }

    /// Which of `candidates` the user means by `typed` (with the focused window for context, as
    /// "the other screen" depends on it): the index, its probability, and the probability that
    /// any candidate fits. nil on any failure; `done` runs on the main thread.
    static func pick(_ typed: String, focused: String?, candidates: [String],
                     _ done: @escaping ((index: Int, p: Double, fits: Double)?) -> Void) {
        withKey { key in
            guard let key, !candidates.isEmpty else { return done(nil) }
            let ids = candidates.indices.map { String(format: "c%03d", $0) }
            let body: [String: Any] = [
                "model": "jev-latest",
                "state": ["typed": typed, "focused_window": focused ?? "none",
                          "candidates": Dictionary(uniqueKeysWithValues: zip(ids, candidates))],
                "questions": [
                    "pick": ["type": "choice",
                             "instructions": "The user typed `typed` into a launcher on their Mac to switch to a window, tab or app, or to run a command. Which of `candidates` do they most likely want?",
                             "criteria": Dictionary(uniqueKeysWithValues: ids.map { ($0, NSNull()) })],
                    "fits": ["type": "noul",
                             "instructions": "Does any of `candidates` match what the user wants by typing `typed`?"],
                ],
            ]
            var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, timeoutInterval: 3)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: req) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let answers = json?["answers"] as? [String: Any]
                let probabilities = (answers?["pick"] as? [String: Any])?["probabilities"] as? [String: Double]
                let fits = (answers?["fits"] as? [String: Any])?["noul"] as? Double
                var out: (index: Int, p: Double, fits: Double)?
                if let probabilities, let fits, let best = probabilities.max(by: { $0.value < $1.value }),
                   let i = ids.firstIndex(of: best.key) {
                    out = (i, best.value, fits)
                } else {
                    Log.write("jev: no answer (HTTP \(status))")
                }
                DispatchQueue.main.async { done(out) }
            }.resume()
        }
    }
}
