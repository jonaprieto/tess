import Foundation
import Testing
@testable import Layout

@Test func pomodoroWorksThenRestsThenWorksAgain() {
    let start = Date(timeIntervalSince1970: 0)
    let p = Pomodoro(start: start)
    func at(_ minutes: Double) -> (Bool, TimeInterval) {
        let ph = p.phase(at: start.addingTimeInterval(minutes * 60))
        return (ph.working, ph.left)
    }
    #expect(at(0) == (true, 25 * 60))
    #expect(at(24.5) == (true, 30))
    #expect(at(25) == (false, 5 * 60))
    #expect(at(29) == (false, 60))
    #expect(at(30) == (true, 25 * 60))
    #expect(at(-1) == (true, 25 * 60))  // a clock set back does not count down from the future
}
