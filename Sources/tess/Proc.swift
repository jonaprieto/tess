import Foundation

/// The one way tess runs another program (osascript, sqlite3, rg, mdfind, folio): started
/// on the calling thread, read in the background, stopped with whatever it started after
/// `timeout`, and its stdout handed to `done` (nil when it failed or was stopped).
enum Proc {
    /// Launchd starts tess with a bare PATH; Homebrew tools live here.
    static let env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                      "HOME": FileManager.default.homeDirectoryForCurrentUser.path]

    /// `log` names the program in tess.log when it exits with an error.
    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String]? = nil, timeout: Double, onMain: Bool = true,
                    log: String? = nil, _ done: @escaping (String?) -> Void) -> Process? {
        func deliver(_ text: String?) {
            if onMain { DispatchQueue.main.async { done(text) } } else { done(text) }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            deliver(nil)
            return nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { stop(p) }
        // stderr is drained on its own, so a chatty program cannot fill it and hang.
        var problem = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            problem = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        DispatchQueue.global().async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            errDone.wait()
            if p.terminationStatus != 0, let log {
                Log.write("\(log): \(String(decoding: problem, as: UTF8.self).prefix(300))")
            }
            deliver(p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
        }
        return p
    }

    /// Stops a process and what it started (a shell's rg, fzf or folio), which would
    /// otherwise keep running and keep the output pipe open.
    static func stop(_ p: Process?) {
        guard let p, p.isRunning else { return }
        let kids = Process()
        kids.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kids.arguments = ["-TERM", "-P", "\(p.processIdentifier)"]
        try? kids.run()
        kids.waitUntilExit()
        p.terminate()
    }
}
