import Foundation
import Testing
@testable import Layout

@Test func emptyWorldHasNoWindows() {
    #expect(World().tiled.isEmpty)
}
