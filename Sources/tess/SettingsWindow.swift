import AppKit
import Layout
import SwiftUI

/// The native settings window. It edits the merged config and saves only what differs from
/// the defaults to `~/.config/tess/config.json`.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(raw: Config.Raw, save: @escaping (Config.Raw) -> String?) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "tess Settings"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        w.contentView = NSHostingView(rootView: SettingsView(model: SettingsModel(raw: raw, save: save)))
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
        float = raw.float ?? []
        tile = raw.tile ?? []
        ignore = raw.ignore ?? []
        func rows(_ d: [String: String?]?) -> [Row] {
            (d ?? [:]).compactMap { k, v in v.map { Row(key: k, value: $0) } }.sorted { $0.key < $1.key }
        }
        verbs = rows(raw.verbs)
        modes = (raw.modes ?? [:]).mapValues(rows)
    }

    var raw: Config.Raw {
        var r = Config.Raw()
        r.gaps = .init(inner: inner, outer: outer)
        r.float = float
        r.tile = tile
        r.ignore = ignore
        func dict(_ rows: [Row]) -> [String: String?] {
            Dictionary(rows.filter { !$0.key.isEmpty }.map { ($0.key, Optional($0.value)) }) { _, last in last }
        }
        r.verbs = dict(verbs)
        r.modes = modes.mapValues(dict)
        return r
    }

    /// Rows whose key or command does not parse (Save is disabled while there are any).
    var invalid: Int {
        modes.values.joined().filter { !$0.key.isEmpty && ((try? KeySpec.parse($0.key)) == nil || (try? Command.parse($0.value)) == nil) }.count
    }

    func save() {
        let r = raw
        message = saveRaw(r)
        failed = message != nil
        if message == nil {
            message = "Saved"
            original = r
        }
    }

    func revert() {
        let fresh = SettingsModel(raw: original, save: saveRaw)
        (inner, outer, float, tile, ignore, verbs, modes) =
            (fresh.inner, fresh.outer, fresh.float, fresh.tile, fresh.ignore, fresh.verbs, fresh.modes)
        message = nil
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
                AppsTab(model: model).tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                KeysTab(model: model).tabItem { Label("Keys", systemImage: "keyboard") }
            }
            .padding([.horizontal, .top])
            HStack {
                if let m = model.message {
                    Label(m, systemImage: model.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.failed ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Revert") { model.revert() }
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(model.invalid > 0)
                    .help(model.invalid > 0 ? "\(model.invalid) key binding(s) need fixing" : "")
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}

struct GeneralTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Gaps") {
                Stepper(value: $model.inner, in: 0...60, step: 2) {
                    LabeledContent("Between windows", value: "\(Int(model.inner)) pt")
                }
                Stepper(value: $model.outer, in: 0...60, step: 2) {
                    LabeledContent("Around the screen", value: "\(Int(model.outer)) pt")
                }
            }
            Section {
                ForEach($model.verbs) { $row in
                    HStack {
                        TextField("verb", text: $row.key).frame(width: 90).font(.body.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        TextField("app name", text: $row.value)
                        Button { model.verbs.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    .labelsHidden()
                }
                Button("Add Verb") { model.verbs.append(.init(key: "", value: "")) }
            } header: {
                Text("Picker verbs")
            } footer: {
                Text("Typing a verb and a folder in the picker opens the folder with that app, e.g. cd ~/anoma.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            AppList(title: "Float", help: "Their windows are never tiled.", ids: $model.float)
            AppList(title: "Tile", help: "Tiled even without a fullscreen button.", ids: $model.tile)
            AppList(title: "Ignore", help: "tess never touches them (EdgeMark's panel, for one).", ids: $model.ignore)
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
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                        .resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading) {
                        Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { ids.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("bundle id, e.g. com.apple.Preview", text: $typed)
                    .labelsHidden()
                    .font(.body.monospaced())
                    .onSubmit(addTyped)
                Button("Add", action: addTyped).disabled(typed.isEmpty)
            }
            Menu("Add Running App") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                    .compactMap { app in app.bundleIdentifier.map { (id: $0, name: app.localizedName ?? $0) } }
                    .filter { !ids.contains($0.id) }.sorted { $0.name < $1.name }, id: \.id) { app in
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
        Binding(get: { model.modes[model.mode] ?? [] }, set: { model.modes[model.mode] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading) {
            SwiftUI.Picker("Mode", selection: $model.mode) {
                ForEach(model.modes.keys.sorted(), id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            List {
                ForEach(rows) { $row in
                    HStack {
                        let keyOK = (try? KeySpec.parse(row.key)) != nil
                        let commandOK = (try? Command.parse(row.value)) != nil
                        Image(systemName: keyOK && commandOK ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(keyOK && commandOK ? Color.secondary : Color.red)
                        TextField("alt-shift-h", text: $row.key).font(.body.monospaced()).frame(width: 200)
                        TextField("command", text: $row.value).font(.body.monospaced())
                        Button { rows.wrappedValue.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Button("Add Binding") { rows.wrappedValue.append(.init(key: "", value: "")) }
                Spacer()
                Text("Keys like alt-shift-h or cmd-alt-ctrl-shift-g; commands as in `tess default-config`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
