import AppKit
import Layout

final class Tutorial: NSWindowController {
    struct Step {
        let title: String
        let body: String
    }
    static func steps(_ config: Config) -> [Step] {
        func key(_ command: Command, mode: String = "main") -> String {
            config.modes[mode]?.filter { $0.value == [command] }.keys.sorted { $0.description < $1.description }
                .first?.symbol ?? "tess \(command.description)"
        }
        let searches: [(PickerSearch, String, String)] = [(.files, "notes", "find files by name"),
            (.text, "hello", "search inside files"), (.books, "title author", "find books"),
            (.papers, "title author", "find papers")]
        let examples = searches.compactMap { kind, query, purpose -> String? in
            guard let verb = config.verbs.filter({ PickerSearch(verb: $0.value) == kind }).keys
                .sorted(by: { ($0.count, $0) < ($1.count, $1) }).first else { return nil }
            return "\(verb) \(query) — \(purpose)"
        }.joined(separator: "\n")
        return [
            Step(title: "Your keyboard is enough", body: "Tess works with your laptop keyboard or any standard Mac keyboard. No NuPhy software, special layers or Hyper key is needed.\n\n⌘ means Command, ⌥ means Option, ⇧ means Shift, and ⌃ means Control.\n\nThis walkthrough changes no bindings or window layouts. Use Next and Back at your own pace."),
            Step(title: "Find a window or app", body: "Open the picker with ⌘Space when available, or \(key(.pick(""))). Spotlight may need its ⌘Space shortcut disabled first.\n\nChoose Try the Picker, type an app name, then press Esc to return here. Use ↑/↓ to browse. Enter continues to placement.\n\nThis is the real picker: confirming a placement can move a window. Canceling leaves its layout unchanged."),
            Step(title: "Choose where it goes", body: "After choosing a window or app, the picker shows your screens. Enter places it beside the focused window. A number chooses a screen; G just goes to it; F floats it.\n\nA letter swaps with that window; Option + letter goes beside it. Esc returns to the results, then Esc closes the picker."),
            Step(title: "Move around with the keyboard", body: "Use \(key(.mode("tess"))) to enter Tess mode. Letters on windows and tabs let you go directly to them. The key guide shows your current bindings.\n\nUse \(key(.mode("resize"))) to enter resize mode. Its guide shows which keys adjust width and height. Esc returns to the previous mode.\n\nTry these on your own windows after closing this walkthrough."),
            Step(title: "Search and recall", body: "Search examples for your configuration:\n\(examples.isEmpty ? "No search verbs are configured." : examples)\n\nAfter confirming a query, type its prefix and press Tab to complete it. Tab in an empty field recalls the latest query. Enter still chooses a result.\n\nBook/paper downloads show their title and progress. Results depend on installed tools and network access."),
            Step(title: "Help when you need it", body: "The menu bar has Settings, Pause Tiling, Tutorial and Doctor.\n\nChoose Doctor to check permissions, configuration and the binaries each feature uses. You can also run tess doctor in a terminal. Missing optional tools do not stop window management.\n\nRun tess default-config to see the default bindings. Your overrides live in ~/.config/tess/config.json."),
        ]
    }

    private var pages: [Step] = []
    private(set) var index = 0
    private let heading = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let next = NSButton(title: "Next", target: nil, action: nil)
    private let practice = NSButton(title: "Try the Picker", target: nil, action: nil)
    var onPicker: () -> Void = {}

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Getting Started with Tess"
        window.isReleasedWhenClosed = false
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        heading.frame = NSRect(x: 28, y: 305, width: 504, height: 48)
        body.font = .systemFont(ofSize: 15)
        body.frame = NSRect(x: 28, y: 78, width: 504, height: 224)
        count.textColor = .secondaryLabelColor
        count.frame = NSRect(x: 28, y: 31, width: 70, height: 20)
        for (button, x, action) in [(practice, CGFloat(112), #selector(tryPicker)), (back, 340, #selector(goBack)), (next, 438, #selector(goNext))] {
            button.frame = NSRect(x: x, y: 24, width: button === practice ? 150 : 94, height: 32)
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        next.keyEquivalent = "\r"
        for view in [heading, body, count, practice, back, next] as [NSView] { window.contentView?.addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }

    func show(_ config: Config) {
        pages = Self.steps(config)
        index = 0
        update()
        window?.center()
        resume()
    }
    func resume() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    private func update() {
        heading.stringValue = pages[index].title
        body.stringValue = pages[index].body
        count.stringValue = "\(index + 1) of \(pages.count)"
        back.isEnabled = index > 0
        next.title = index == pages.count - 1 ? "Done" : "Next"
        practice.isHidden = index != 1
    }
    @objc func goBack() { if index > 0 { index -= 1; update() } }
    @objc func goNext() {
        if index == pages.count - 1 { close() } else { index += 1; update() }
    }
    @objc private func tryPicker() { onPicker() }
}
