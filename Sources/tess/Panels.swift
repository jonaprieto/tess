import AppKit

@MainActor
enum Panels {
  /// Borders and highlights: the config's overlay.border_color, else
  /// the macOS accent color.
  static var accent = NSColor.controlAccentColor
  static var inactiveBorder = label(0.22)
  static var selection = NSColor.systemOrange
  /// Details and hints in small type: the system's secondary label
  /// falls short of 4.5:1 on light glass.
  static let quiet = label(0.62)

  /// The label color at `alpha`, following the theme:
  /// `withAlphaComponent` outside drawing keeps the theme of the
  /// moment, and a color kept across a switch would stay in it.
  static func label(_ alpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      var out = NSColor.labelColor
      appearance.performAsCurrentDrawingAppearance {
        out =
          NSColor.labelColor.usingColorSpace(.sRGB)?
          .withAlphaComponent(alpha) ?? out
      }
      return out
    }
  }

  /// Contrast between two colors as WCAG measures it, from 1 to 21.
  /// Their alpha is ignored.
  static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    func luminance(_ c: NSColor) -> CGFloat {
      guard let s = c.usingColorSpace(.sRGB) else { return 0 }
      func linear(_ v: CGFloat) -> CGFloat {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * linear(s.redComponent) + 0.7152
        * linear(s.greenComponent) + 0.0722 * linear(s.blueComponent)
    }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }

  /// Black or white, whichever reads on `fill`: white on a pale
  /// accent or on orange does not.
  static func ink(on fill: NSColor) -> NSColor {
    contrast(.black, fill) > contrast(.white, fill) ? .black : .white
  }

  /// `color` for text and thin lines in the appearance, darkened on a
  /// light one or lightened on a dark one only as far as it takes to
  /// reach 4.5:1 on the darker or lighter cells that text sits on.
  /// Orange, mint or a pale accent are fine on dark and nearly
  /// invisible on light.
  static func readable(_ color: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      var out = color
      appearance.performAsCurrentDrawingAppearance {
        let dark =
          appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ground = NSColor(white: dark ? 0.24 : 0.82, alpha: 1)
        let base = color.usingColorSpace(.sRGB) ?? color
        out = base
        var moved: CGFloat = 0
        while contrast(out, ground) < 4.5, moved < 1 {
          moved += 0.05
          out =
            base.blended(
              withFraction: moved, of: dark ? .white : .black) ?? out
        }
      }
      return out
    }
  }

  /// A borderless, click-through panel on every Space that never
  /// takes focus. In Mission Control `.stationary` stays where it is
  /// and `.transient` hides.
  static func overlay(
    level: NSWindow.Level,
    missionControl: NSWindow.CollectionBehavior = .stationary
  ) -> NSPanel {
    let p = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    p.level = level
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.ignoresMouseEvents = true
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.collectionBehavior = [
      .canJoinAllSpaces, missionControl, .ignoresCycle,
      .fullScreenAuxiliary
    ]
    return p
  }

  /// `view` on the system glass, with rounded corners.
  static func glass(_ view: NSView, radius: CGFloat)
    -> NSGlassEffectView
  {
    let g = NSGlassEffectView()
    g.cornerRadius = radius
    g.contentView = view
    return g
  }
}
