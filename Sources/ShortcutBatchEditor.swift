import AppKit
import Carbon.HIToolbox

// MARK: - 默认预设与严格 JSON 校验

enum ShortcutConfiguration {
    static let screenSaver = "/System/Library/CoreServices/ScreenSaverEngine.app"
    static let defaults = Config(hotkeys: [
        HotkeyBinding(key: "a", modifiers: ["command", "option"], target: "Crest"),
        HotkeyBinding(key: "f", modifiers: ["command", "option"], target: "Lark"),
        HotkeyBinding(key: "o", modifiers: ["command", "option"], target: "Obsidian"),
        HotkeyBinding(key: "t", modifiers: ["command", "option"], target: "Trae CN"),
        HotkeyBinding(key: "c", modifiers: ["command", "option"], target: "Craft"),
        HotkeyBinding(key: "l", modifiers: ["command", "control"], target: screenSaver),
        HotkeyBinding(key: "x", modifiers: ["command", "option"], target: "WeChat"),
        HotkeyBinding(key: "d", modifiers: ["command", "option"], target: "Doubao")
    ])

    static func json(_ config: Config) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"hotkeys\":[]}"
    }
    static func identity(_ binding: HotkeyBinding) -> String {
        "\(KeyCodes.map[binding.key.lowercased()] ?? -1):\(KeyCodes.carbonModifiers(binding.modifiers))"
    }
    static func parse(_ text: String, resolveTargets: Bool = true) throws -> Config {
        func fail(_ message: String) -> NSError {
            NSError(domain: "MacKit.ShortcutConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let data = text.data(using: .utf8), data.count <= 1_000_000 else { throw fail("配置过大，最多 1 MB") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw fail("JSON 格式错误：\(error.localizedDescription)") }
        guard let root = object as? [String: Any], Set(root.keys) == ["hotkeys"],
              let raw = root["hotkeys"] as? [[String: Any]], raw.count <= 200 else {
            throw fail("顶层只允许 hotkeys 数组，最多 200 条")
        }
        var seen = Set<String>()
        var bindings: [HotkeyBinding] = []
        for (index, row) in raw.enumerated() {
            let prefix = "第 \(index + 1) 条："
            guard Set(row.keys) == ["key", "modifiers", "target"],
                  let key = row["key"] as? String, let modifiers = row["modifiers"] as? [String],
                  let target = row["target"] as? String else {
                throw fail(prefix + "需要 key、modifiers 数组、target 三个字段")
            }
            guard let code = KeyCodes.map[key.lowercased()] else { throw fail(prefix + "不支持按键 \(key)") }
            guard modifiers.allSatisfy({ KeyCodes.canonicalModifier($0) != nil }) else { throw fail(prefix + "存在未知修饰键") }
            let canonical = KeyCodes.canonicalModifiers(modifiers)
            guard !Set(canonical).isDisjoint(with: ["command", "option", "control"]) else {
                throw fail(prefix + "至少包含 command、option、control 中的一个")
            }
            let mods = KeyCodes.carbonModifiers(canonical)
            if (mods == UInt32(optionKey) && code == 49)
                || (mods == UInt32(optionKey | cmdKey) && [40, 43].contains(code)) {
                throw fail(prefix + "该组合是 MacKit 保留热键")
            }
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw fail(prefix + "目标不能为空") }
            if resolveTargets {
                guard let url = AppResolver.resolve(trimmed), url.pathExtension == "app", Bundle(url: url) != nil else {
                    throw fail(prefix + "找不到应用 \(trimmed)")
                }
            }
            let binding = HotkeyBinding(key: KeyCodes.name(for: UInt16(code)) ?? key.lowercased(), modifiers: canonical, target: trimmed)
            guard seen.insert(identity(binding)).inserted else { throw fail(prefix + "快捷键重复（包括等价别名）") }
            bindings.append(binding)
        }
        return Config(hotkeys: bindings)
    }
}

// MARK: - 原生批量编辑窗口

/// 不依赖应用菜单的标准文本编辑；⌘S 继续交给窗口的保存按钮。
private final class BatchTextView: NSTextView {
    var editPasteboard: NSPasteboard = .general

    @discardableResult
    func handleEditingKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard flags == [.command] || flags == [.command, .shift] else { return false }
        switch (event.keyCode, flags.contains(.shift)) {
        case (0, false): selectAll(nil)
        case (8, false): copy(nil)
        case (7, false): cut(nil)
        case (9, _): paste(nil)
        case (6, false): undoManager?.undo()
        case (6, true): undoManager?.redo()
        default: return false
        }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        return handleEditingKey(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !handleEditingKey(event) { super.keyDown(with: event) }
    }
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        editPasteboard.clearContents()
        editPasteboard.setString((string as NSString).substring(with: range), forType: .string)
    }
    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange().length > 0 else { return }
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let text = editPasteboard.string(forType: .string)
            ?? editPasteboard.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        guard let text else { return }
        insertText(text, replacementRange: selectedRange())
    }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
}

final class ShortcutBatchEditor: NSWindowController {
    private let editor = BatchTextView()
    private var editingMonitor: Any?
    private let message = NSTextField(wrappingLabelWithString: "修改完整 JSON，保存后立即生效；校验失败不会覆盖原配置。")
    private let save: (String) -> String?

    init(config: Config, save: @escaping (String) -> String?) {
        self.save = save
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "批量编辑快捷键"
        window.minSize = NSSize(width: 560, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setup(config)
        editingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  event.window === window, window.firstResponder === self.editor else { return event }
            return self.editor.handleEditingKey(event) ? nil : event
        }
    }
    deinit { if let editingMonitor { NSEvent.removeMonitor(editingMonitor) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    private func setup(_ config: Config) {
        guard let root = window?.contentView else { return }
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.setAccessibilityLabel("快捷键 JSON 编辑器")
        editor.setAccessibilityIdentifier("batchShortcutEditor")
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = ShortcutConfiguration.json(config)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = editor
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        let format = NSButton(title: "校验并格式化", target: self, action: #selector(formatJSON))
        let preset = NSButton(title: "载入默认配置", target: self, action: #selector(loadDefaults))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEditing))
        let apply = NSButton(title: "保存并应用", target: self, action: #selector(applyJSON))
        apply.keyEquivalent = "s"
        apply.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [format, preset, NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [message, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func formatJSON() {
        do {
            let config = try ShortcutConfiguration.parse(editor.string)
            editor.string = ShortcutConfiguration.json(config)
            message.stringValue = "格式和目标有效，共 \(config.hotkeys.count) 条；保存时还会检查热键占用。"
            message.textColor = .secondaryLabelColor
        } catch { showError(error.localizedDescription) }
    }
    @objc private func loadDefaults() {
        editor.string = ShortcutConfiguration.json(ShortcutConfiguration.defaults)
        message.stringValue = "已载入截图中的 8 条默认配置，尚未保存。"
        message.textColor = .secondaryLabelColor
    }
    @objc private func cancelEditing() { close() }
    @objc private func applyJSON() {
        if let error = save(editor.string) { showError(error) }
        else { close() }
    }
    private func showError(_ text: String) { message.stringValue = text; message.textColor = .systemOrange }
}

func runBatchEditingCheck() -> Never {
    _ = NSApplication.shared
    let board = NSPasteboard(name: NSPasteboard.Name("MacKit-Edit-Test-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let editor = BatchTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    editor.editPasteboard = board
    editor.isRichText = false
    editor.allowsUndo = true
    let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = editor
    window.makeFirstResponder(editor)
    func event(_ code: UInt16, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    func require(_ condition: Bool, _ name: String) { if !condition { print("✗ 批量编辑：" + name); exit(1) } }
    let sample = "{\"hotkeys\":[]}\n中文测试"
    editor.string = sample
    require(editor.performKeyEquivalent(with: event(0)) && editor.selectedRange().length == (sample as NSString).length, "⌘A")
    require(editor.performKeyEquivalent(with: event(8)) && board.string(forType: .string) == sample, "⌘C")
    require(editor.performKeyEquivalent(with: event(7)) && editor.string.isEmpty, "⌘X")
    require(editor.performKeyEquivalent(with: event(9)) && editor.string == sample, "⌘V")
    editor.selectAll(nil)
    board.clearContents()
    board.setString("纯文本粘贴", forType: .string)
    require(editor.performKeyEquivalent(with: event(9, shift: true)) && editor.string == "纯文本粘贴", "⌘⇧V")
    require(editor.performKeyEquivalent(with: event(6)) && editor.string == sample, "⌘Z")
    require(editor.performKeyEquivalent(with: event(6, shift: true)) && editor.string == "纯文本粘贴", "⌘⇧Z")
    require(!editor.performKeyEquivalent(with: event(1)), "⌘S 交给保存按钮")
    window.makeFirstResponder(nil)
    require(!editor.performKeyEquivalent(with: event(8)), "失焦不抢快捷键")
    print("✓ 批量编辑：全选、复制、剪切、纯文本粘贴、撤销/重做及失焦隔离通过（隔离剪贴板）")
    exit(0)
}

func runShortcutConfigurationCheck() -> Never {
    var passed = 0
    func require(_ value: Bool) { if !value { print("✗ 批量配置自检失败（检查 \(passed + 1)）"); exit(1) }; passed += 1 }
    do {
        let config = try ShortcutConfiguration.parse(ShortcutConfiguration.json(ShortcutConfiguration.defaults))
        require(config.hotkeys.count == 8)
        require(config.hotkeys.map(\.key) == ["a", "f", "o", "t", "c", "l", "x", "d"])
        require(config.hotkeys[5].target == ShortcutConfiguration.screenSaver)
        require(Set(config.hotkeys[5].modifiers) == ["control", "command"])
        require(config.hotkeys.enumerated().allSatisfy { $0.offset == 5 || Set($0.element.modifiers) == ["option", "command"] })
        let invalid = ["bad JSON", "{\"hotkeys\":[{\"key\":\"space\",\"modifiers\":[\"alt\"],\"target\":\"Crest\"}]}",
            "{\"hotkeys\":[{\"key\":\"a\",\"modifiers\":[\"typo\"],\"target\":\"Crest\"}]}",
            "{\"hotkeys\":[{\"key\":\"a\",\"modifiers\":[\"shift\"],\"target\":\"Crest\"}]}",
            "{\"hotkeys\":[{\"key\":\"a\",\"modifiers\":[\"command\"],\"target\":\"\"}]}",
            "{\"hotkeys\":[],\"unexpected\":1}"]
        for input in invalid {
            var rejected = false
            do { _ = try ShortcutConfiguration.parse(input, resolveTargets: false) } catch { rejected = true }
            require(rejected)
        }
        let aliasDuplicate = Config(hotkeys: [HotkeyBinding(key: "return", modifiers: ["alt"], target: "Crest"), HotkeyBinding(key: "enter", modifiers: ["option"], target: "Crest")])
        var rejected = false
        do { _ = try ShortcutConfiguration.parse(ShortcutConfiguration.json(aliasDuplicate), resolveTargets: false) } catch { rejected = true }
        require(rejected)
        let empty = try ShortcutConfiguration.parse("{\"hotkeys\":[]}")
        require(empty.hotkeys.isEmpty)
        print("✓ \(passed) 项通过：截图8条预设、应用目标、屏保、严格JSON、保留键、别名去重与空列表")
        exit(0)
    } catch { print("✗ \(error.localizedDescription)"); exit(1) }
}
