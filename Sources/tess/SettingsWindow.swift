import AppKit
import Layout
import SwiftUI

/// The native settings window. It edits the merged config and saves
/// only what differs from the defaults to
/// `~/.config/tess/config.json`.
final class SettingsWindow {
  static let shared = SettingsWindow()
  private var window: NSWindow?

  /// Opens on `screen` (AX coordinates) when given and not already
  /// open.
  func show(
    raw: Config.Raw, on screen: CGRect?,
    save: @escaping (Config.Raw) -> String?
  ) {
    let w =
      window
      ?? {
        let w = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
          styleMask: [
            .titled, .closable, .miniaturizable, .resizable
          ], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        return w
      }()
    w.title = L("tess Settings")
    let saved: (Config.Raw) -> String? = { [weak w] raw in
      defer { w?.title = L("tess Settings") }
      return save(raw)
    }
    w.contentView = NSHostingView(
      rootView: SettingsView(
        model: SettingsModel(raw: raw, save: saved)))
    if let screen, !w.isVisible {
      let f = Screens.flip(screen)
      w.setFrameOrigin(
        NSPoint(
          x: f.midX - w.frame.width / 2,
          y: f.midY - w.frame.height / 2))
    }
    NSApp.activate()
    w.makeKeyAndOrderFront(nil)
  }
}

@Observable
final class SettingsModel {
  struct Row: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
  }

  var inner: Double
  var outer: Double
  var overlayAllScreens: Bool
  var grayOthers: Bool
  var grayAmount: Double
  var borderColor: Color
  var inactiveBorderColor: Color
  var selectionColor: Color
  var emptyScreens: Bool
  var ribbon: Bool
  var updateCheck: Bool
  var windowLabels: Config.LabelMode
  /// A language code; nil is macOS's.
  var language: String?
  /// What the window is shown in: the view is built again when a save
  /// changes it.
  var shownIn = Strings.language
  var float: [String]
  var tile: [String]
  var ignore: [String]
  var verbs: [Row]
  var modes: [String: [Row]]
  var mode = "main"
  var message: String?
  var failed = false
  private var original: Config.Raw
  private let saveRaw: (Config.Raw) -> String?

  init(raw: Config.Raw, save: @escaping (Config.Raw) -> String?) {
    original = raw
    saveRaw = save
    inner = raw.gaps?.inner ?? 10
    outer = raw.gaps?.outer ?? 10
    overlayAllScreens = raw.overlay?.allScreens ?? true
    grayOthers = raw.overlay?.grayOthers ?? true
    grayAmount = raw.overlay?.grayAmount ?? 0.8
    let config = (try? Config.validate(raw)) ?? Config.defaults
    func color(_ rgb: [Double]?, fallback: NSColor) -> Color {
      Color(
        nsColor: rgb.map {
          NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: 1)
        } ?? fallback)
    }
    borderColor = color(
      config.borderColor, fallback: .controlAccentColor)
    inactiveBorderColor = color(
      config.inactiveBorderColor, fallback: .labelColor)
    selectionColor = color(
      config.selectionColor, fallback: .systemOrange)
    emptyScreens = raw.emptyScreens ?? true
    ribbon = raw.ribbon ?? false
    updateCheck = raw.updateCheck ?? true
    windowLabels = raw.overlay?.windowLabels ?? .jump
    language = raw.language
    float = raw.float ?? []
    tile = raw.tile ?? []
    ignore = raw.ignore ?? []
    func rows(_ d: [String: String?]?) -> [Row] {
      (d ?? [:]).compactMap { k, v in v.map { Row(key: k, value: $0) }
      }.sorted { $0.key < $1.key }
    }
    verbs = rows(raw.verbs)
    modes = (raw.modes ?? [:]).mapValues(rows)
  }

  var raw: Config.Raw {
    // What the window does not edit (history) stays as it was.
    var r = original
    r.gaps = .init(inner: inner, outer: outer)
    var overlay = r.overlay ?? .init()
    overlay.allScreens = overlayAllScreens
    overlay.windowLabels = windowLabels
    overlay.grayOthers = grayOthers
    overlay.grayAmount = grayAmount
    // Keep system colors dynamic until the user actually changes a
    // color.
    let saved = SettingsModel(raw: original, save: saveRaw)
    func hex(_ color: Color) -> String {
      let c = NSColor(color).usingColorSpace(.sRGB)!
      return String(
        format: "#%02x%02x%02x",
        Int((c.redComponent * 255).rounded()),
        Int((c.greenComponent * 255).rounded()),
        Int((c.blueComponent * 255).rounded()))
    }
    if borderColor != saved.borderColor {
      overlay.borderColor = hex(borderColor)
    }
    if inactiveBorderColor != saved.inactiveBorderColor {
      overlay.inactiveBorderColor = hex(inactiveBorderColor)
    }
    if selectionColor != saved.selectionColor {
      overlay.selectionColor = hex(selectionColor)
    }
    r.overlay = overlay
    r.emptyScreens = emptyScreens
    r.ribbon = ribbon
    r.updateCheck = updateCheck
    r.language = language
    r.float = float
    r.tile = tile
    r.ignore = ignore
    func dict(_ rows: [Row]) -> [String: String?] {
      Dictionary(
        rows.filter { !$0.key.isEmpty }.map {
          ($0.key, Optional($0.value))
        }
      ) { _, last in last }
    }
    r.verbs = dict(verbs)
    r.modes = modes.mapValues(dict)
    return r
  }

  /// Rows whose key or command does not parse (Save is disabled while
  /// there are any).
  var invalid: Int {
    modes.values.joined().filter {
      !$0.key.isEmpty
        && ((try? KeySpec.parse($0.key)) == nil
          || (try? Command.parse($0.value)) == nil)
    }.count
  }

  func save() {
    let r = raw
    message = saveRaw(r)
    failed = message != nil
    if message == nil {
      shownIn = Strings.language
      message = L("Saved")
      original = r
    }
  }

  func revert() {
    let fresh = SettingsModel(raw: original, save: saveRaw)
    ribbon = fresh.ribbon
    updateCheck = fresh.updateCheck
    (
      inner, outer, overlayAllScreens, grayOthers, emptyScreens,
      windowLabels, float, tile, ignore, verbs, modes
    ) =
      (
        fresh.inner, fresh.outer, fresh.overlayAllScreens,
        fresh.grayOthers, fresh.emptyScreens, fresh.windowLabels,
        fresh.float, fresh.tile,
        fresh.ignore, fresh.verbs, fresh.modes
      )
    language = fresh.language
    grayAmount = fresh.grayAmount
    borderColor = fresh.borderColor
    inactiveBorderColor = fresh.inactiveBorderColor
    selectionColor = fresh.selectionColor
    message = nil
  }
}

struct SettingsView: View {
  @Bindable var model: SettingsModel

  var body: some View {
    VStack(spacing: 0) {
      TabView {
        GeneralTab(model: model).tabItem {
          Label(L("General"), systemImage: "gearshape")
        }
        AppearanceTab(model: model).tabItem {
          Label(L("Appearance"), systemImage: "paintpalette")
        }
        AppsTab(model: model).tabItem {
          Label(L("Apps"), systemImage: "square.grid.2x2")
        }
        KeysTab(model: model).tabItem {
          Label(L("Keys"), systemImage: "keyboard")
        }
      }
      .padding([.horizontal, .top])
      HStack {
        if let m = model.message {
          Label(
            m,
            systemImage: model.failed
              ? "exclamationmark.triangle.fill"
              : "checkmark.circle.fill"
          )
          .foregroundStyle(model.failed ? .red : .secondary)
          .lineLimit(2)
        }
        Spacer()
        Button(L("Revert")) { model.revert() }
        Button(L("Save")) { model.save() }
          .keyboardShortcut("s")
          .buttonStyle(.borderedProminent)
          .disabled(model.invalid > 0)
          .help(
            model.invalid > 0
              ? L("\(model.invalid) key binding(s) need fixing") : "")
      }
      .padding()
    }
    .frame(minWidth: 620, minHeight: 480)
    .id(model.shownIn)
  }
}

struct GeneralTab: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
      Section {
        SwiftUI.Picker(L("Language"), selection: $model.language) {
          Text(L("Same as macOS")).tag(String?.none)
          Text("English").tag(String?.some("en"))
          Text("Español").tag(String?.some("es"))
        }
      }
      Section(L("Gaps")) {
        Stepper(value: $model.inner, in: 0...60, step: 2) {
          LabeledContent(
            L("Between windows"), value: "\(Int(model.inner)) pt")
        }
        Stepper(value: $model.outer, in: 0...60, step: 2) {
          LabeledContent(
            L("Around the screen"), value: "\(Int(model.outer)) pt")
        }
      }
      Section {
        Toggle(L("Use empty screens"), isOn: $model.emptyScreens)
      } footer: {
        Text(
          L(
            "New windows open on an empty screen when there is one; Settings and a mode's keys show on the screen with the fewest windows."
          )
        )
        .foregroundStyle(.secondary)
      }
      Section {
        Toggle(L("Ribbon on every screen"), isOn: $model.ribbon)
      } footer: {
        Text(
          L(
            "Columns keep their width and run past the screen: the view scrolls to the window in use, and the rest wait along the bottom with their title bars showing."
          )
        )
        .foregroundStyle(.secondary)
      }
      Section {
        Toggle(L("Check for updates"), isOn: $model.updateCheck)
      } footer: {
        Text(
          L(
            "Once a day tess asks GitHub for its latest version, and tells you when there is a newer one."
          )
        )
        .foregroundStyle(.secondary)
      }
      Section(L("Overlays")) {
        Toggle(
          L("Show a mode's keys on every screen"),
          isOn: $model.overlayAllScreens
        )
        .disabled(model.emptyScreens)
        SwiftUI.Picker(
          L("Borders and letters"), selection: $model.windowLabels
        ) {
          Text(L("Focused window, letters when jumping")).tag(
            Config.LabelMode.jump)
          Text(L("Every window, always")).tag(Config.LabelMode.always)
          Text(L("Off")).tag(Config.LabelMode.off)
        }
      }
      Section {
        ForEach($model.verbs) { $row in
          HStack {
            TextField(L("verb"), text: $row.key).frame(width: 90)
              .font(.body.monospaced())
            Image(systemName: "arrow.right").foregroundStyle(
              .tertiary)
            TextField(L("app name"), text: $row.value)
            Button {
              model.verbs.removeAll { $0.id == row.id }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
          }
          .labelsHidden()
        }
        Button(L("Add Verb")) {
          model.verbs.append(.init(key: "", value: ""))
        }
      } header: {
        Text(L("Picker verbs"))
      } footer: {
        Text(
          L(
            "Typing a verb and a folder in the picker opens the folder with that app, e.g. cd ~/anoma."
          )
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

struct AppearanceTab: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
      Section {
        ColorPicker(
          L("Focused border and highlights"),
          selection: $model.borderColor, supportsOpacity: false)
        ColorPicker(
          L("Inactive borders"),
          selection: $model.inactiveBorderColor,
          supportsOpacity: false)
        ColorPicker(
          L("Selection and drag outlines"),
          selection: $model.selectionColor, supportsOpacity: false)
      } header: {
        Text(L("Colors"))
      } footer: {
        Text(
          L(
            "Inactive borders appear when borders and letters are set to Every window, or while jumping."
          ))
      }
      Section {
        Toggle(L("Gray out other windows"), isOn: $model.grayOthers)
        HStack {
          Slider(value: $model.grayAmount, in: 0...1, step: 0.05) {
            Text(L("Grayscale strength"))
          }
          Text("\(Int((model.grayAmount * 100).rounded()))%")
            .monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .disabled(!model.grayOthers)
      } header: {
        Text(L("Grayscale"))
      } footer: {
        Text(
          L(
            "0% keeps full color; 100% makes other windows black and white. The focused window stays in color."
          ))
      }
    }
    .formStyle(.grouped)
  }
}

struct AppsTab: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
      AppList(
        title: L("Float"), help: L("Their windows are never tiled."),
        ids: $model.float)
      AppList(
        title: L("Tile"),
        help: L("Tiled even without a fullscreen button."),
        ids: $model.tile)
      AppList(
        title: L("Ignore"),
        help: L(
          "tess never touches them (EdgeMark's panel, for one)."),
        ids: $model.ignore)
    }
    .formStyle(.grouped)
  }
}

struct AppList: View {
  let title: String
  let help: String
  @Binding var ids: [String]
  @State private var typed = ""

  private func addTyped() {
    let id = typed.trimmingCharacters(in: .whitespaces)
    if !id.isEmpty, !ids.contains(id) { ids.append(id) }
    typed = ""
  }

  var body: some View {
    Section {
      ForEach(ids, id: \.self) { id in
        HStack {
          let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: id)
          Image(
            nsImage: url.map {
              NSWorkspace.shared.icon(forFile: $0.path)
            } ?? NSImage()
          )
          .resizable().frame(width: 20, height: 20)
          VStack(alignment: .leading) {
            Text(
              url.map {
                FileManager.default.displayName(atPath: $0.path)
              } ?? id)
            Text(id).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            ids.removeAll { $0 == id }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
        }
      }
      HStack {
        TextField(
          L("bundle id, e.g. com.apple.Preview"), text: $typed
        )
        .labelsHidden()
        .font(.body.monospaced())
        .onSubmit(addTyped)
        Button(L("Add"), action: addTyped).disabled(typed.isEmpty)
      }
      Menu(L("Add Running App")) {
        ForEach(
          NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
          }
          .compactMap { app in
            app.bundleIdentifier.map {
              (id: $0, name: app.localizedName ?? $0)
            }
          }
          .filter { !ids.contains($0.id) }.sorted {
            $0.name < $1.name
          }, id: \.id
        ) { app in
          Button(app.name) { ids.append(app.id) }
        }
      }
      .fixedSize()
    } header: {
      Text(title)
    } footer: {
      Text(help).foregroundStyle(.secondary)
    }
  }
}

struct KeysTab: View {
  @Bindable var model: SettingsModel

  private var rows: Binding<[SettingsModel.Row]> {
    Binding(
      get: { model.modes[model.mode] ?? [] },
      set: { model.modes[model.mode] = $0 })
  }

  var body: some View {
    VStack(alignment: .leading) {
      SwiftUI.Picker(L("Mode"), selection: $model.mode) {
        ForEach(model.modes.keys.sorted(), id: \.self) {
          Text($0).tag($0)
        }
      }
      .pickerStyle(.segmented)
      List {
        ForEach(rows) { $row in
          HStack {
            let keyOK = (try? KeySpec.parse(row.key)) != nil
            let commandOK = (try? Command.parse(row.value)) != nil
            Image(
              systemName: keyOK && commandOK
                ? "checkmark.circle" : "exclamationmark.circle"
            )
            .foregroundStyle(
              keyOK && commandOK ? Color.secondary : Color.red)
            TextField("alt-shift-h", text: $row.key).font(
              .body.monospaced()
            ).frame(width: 200)
            TextField(L("command"), text: $row.value).font(
              .body.monospaced())
            Button {
              rows.wrappedValue.removeAll { $0.id == row.id }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
          }
          .labelsHidden()
        }
      }
      HStack {
        Button(L("Add Binding")) {
          rows.wrappedValue.append(.init(key: "", value: ""))
        }
        Spacer()
        Text(
          LocalizedStringKey(
            L(
              "Keys like alt-shift-h or cmd-alt-ctrl-shift-g; commands as in `tess default-config`."
            ))
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
