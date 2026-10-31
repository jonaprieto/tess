import Layout
import SwiftUI
import Testing
@testable import tess

@MainActor
@Test func appearanceEditsSaveAndRevertWithoutLosingOtherSettings() throws {
    var raw = Config.defaultRaw
    raw.overlay?.borderColor = "#112233"
    raw.history = ["com.apple.Safari"]
    var saved: Config.Raw?
    let model = SettingsModel(raw: raw) { saved = $0; return nil }
    #expect(model.raw == raw)
    model.selectionColor = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
    model.inactiveBorderColor = Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1)
    model.grayAmount = 0.25
    model.save()
    #expect(saved?.overlay?.selectionColor == "#ff0000")
    #expect(saved?.overlay?.inactiveBorderColor == "#00ff00")
    #expect(saved?.overlay?.borderColor == "#112233")
    #expect(saved?.overlay?.grayAmount == 0.25)
    #expect(saved?.history == raw.history)
    model.grayAmount = 1
    model.borderColor = .blue
    model.revert()
    #expect(model.raw == saved)
}

@MainActor
@Test func savingAppearanceKeepsUnchangedSystemColorsDynamic() {
    let model = SettingsModel(raw: Config.defaultRaw) { _ in nil }
    model.grayAmount = 0
    #expect(model.raw.overlay?.borderColor == nil)
    #expect(model.raw.overlay?.inactiveBorderColor == nil)
    #expect(model.raw.overlay?.selectionColor == nil)
    #expect(model.raw.overlay?.grayAmount == 0)
}

private func readable(_ color: NSColor, on ground: CGFloat) -> CGFloat {
    Panels.contrast(Panels.readable(color), NSColor(white: ground, alpha: 1))
}

@Test func textReadsOnColorsAndInBothThemes() {
    let pale = NSColor(srgbRed: 0x76 / 255, green: 0xd6 / 255, blue: 1, alpha: 1)
    #expect(Panels.ink(on: pale) == .black)
    #expect(Panels.ink(on: .systemOrange) == .black)
    #expect(Panels.ink(on: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.4, alpha: 1)) == .white)
    for (name, ground) in [(NSAppearance.Name.aqua, CGFloat(0.82)), (.darkAqua, 0.24)] {
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            for color in [pale, .systemOrange, .systemMint, .systemTeal, .systemGray] {
                #expect(readable(color, on: ground) >= 4.5, "\(name) \(color)")
            }
            let quiet = Panels.quiet.usingColorSpace(.sRGB)?.redComponent ?? -1
            #expect(name == .aqua ? quiet < 0.2 : quiet > 0.8)
        }
    }
}
