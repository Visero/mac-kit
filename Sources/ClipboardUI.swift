import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine
import ApplicationServices

// MARK: - 原生剪贴板浮层

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ClipboardPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    private let history: ClipboardHistory
    private let panel: ClipboardPanel
    private let search = NSSearchField()
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let detailIcon = NSImageView()
    private let detailSource = NSTextField(labelWithString: "")
    private let detailMeta = NSTextField(labelWithString: "")
    private let detailText = NSTextView()
    private let detailTextScroll = NSScrollView()
    private let detailImage = NSImageView()
    private let detailEmpty = NSTextField(wrappingLabelWithString: "选中左侧记录，详情显示在这里。")
    private var observation: Any?
    private var previousApp: NSRunningApplication?
    private var rows: [ClipboardEntry] = []
    private var controls: NSStackView!
    private var keyMonitor: Any?
    private var suppressClose = false
    private let leftColumn = NSView()
    private let divider = NSBox()
    private let detail = NSView()
    private let contentStack = NSStackView()

    init(history: ClipboardHistory) {
        self.history = history
        panel = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                               styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.title = "剪贴板历史"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // 无标题栏按钮和留白：整块浮层都是内容，拖动靠背景。
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        // 默认失焦即收起；自检时可临时保持显示以便自动化操作。
        panel.hidesOnDeactivate = ProcessInfo.processInfo.environment["MACKIT_KEEP_PANEL"] != "1"
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        setup()
        reload()
        observation = history.$archive.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    private func setup() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        panel.contentView = root
        search.placeholderString = "搜索文字或来源（⌘1–⌘9 直接取用）"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.controlSize = .small
        search.font = .systemFont(ofSize: 12)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.gridStyleMask = []
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = 300
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(copySelection)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(withTitle: "复制", action: #selector(copySelection), keyEquivalent: "")
        menu.addItem(withTitle: "置顶 / 取消置顶", action: #selector(pinSelection), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "指定快捷键…", action: #selector(assignShortcut), keyEquivalent: "")
        menu.addItem(withTitle: "清除快捷键", action: #selector(clearShortcut), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "删除", action: #selector(deleteSelection), keyEquivalent: "")
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        let copy = NSButton(title: "复制", target: self, action: #selector(copySelection))
        let pin = NSButton(title: "置顶", target: self, action: #selector(pinSelection))
        let delete = NSButton(title: "删除", target: self, action: #selector(deleteSelection))
        let close = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        for button in [copy, pin, delete, close] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        let controls = NSStackView(views: [copy, pin, delete, close])
        self.controls = controls
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailIcon.imageScaling = .scaleProportionallyDown
        detailSource.font = .systemFont(ofSize: 12, weight: .semibold)
        detailSource.lineBreakMode = .byTruncatingTail
        detailSource.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailMeta.font = .systemFont(ofSize: 10)
        detailMeta.textColor = .secondaryLabelColor
        detailMeta.lineBreakMode = .byTruncatingTail
        detailMeta.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailText.isEditable = false
        detailText.isSelectable = true
        detailText.drawsBackground = false
        detailText.font = .systemFont(ofSize: 12)
        detailText.textContainerInset = NSSize(width: 8, height: 8)
        detailText.isVerticallyResizable = true
        detailText.isHorizontallyResizable = false
        detailText.autoresizingMask = [.width]
        detailText.textContainer?.widthTracksTextView = true
        detailTextScroll.documentView = detailText
        detailTextScroll.hasVerticalScroller = true
        detailTextScroll.drawsBackground = false
        detailTextScroll.borderType = .noBorder
        detailTextScroll.scrollerStyle = .overlay
        detailImage.imageScaling = .scaleProportionallyDown
        detailImage.imageAlignment = .alignCenter
        // 预览按可用区域缩放，不能用图片固有尺寸撑大双栏或窗口。
        detailImage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailImage.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        detailEmpty.font = .systemFont(ofSize: 11)
        detailEmpty.textColor = .tertiaryLabelColor
        detailEmpty.alignment = .center

        let sourceLines = NSStackView(views: [detailSource, detailMeta])
        sourceLines.orientation = .vertical
        sourceLines.alignment = .leading
        sourceLines.spacing = 1
        let header = NSStackView(views: [detailIcon, sourceLines])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let body = NSView()
        for view in [header, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(view)
        }
        for view in [detailTextScroll, detailImage, detailEmpty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }

        divider.boxType = .separator
        for view in [scroll, countLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leftColumn.addSubview(view)
        }
        contentStack.addArrangedSubview(leftColumn)
        contentStack.addArrangedSubview(detail)
        contentStack.orientation = .horizontal
        contentStack.distribution = .fillEqually
        contentStack.alignment = .top
        contentStack.spacing = 20
        for view in [leftColumn, detail, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        contentStack.addSubview(divider)

        for view in [search, contentStack, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            search.heightAnchor.constraint(equalToConstant: 24),

            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            // 按钮与左侧计数共享底部空间，不单独新增一行。
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            contentStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            controls.heightAnchor.constraint(equalToConstant: 24),

            scroll.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: leftColumn.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor, constant: 2),
            countLabel.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            countLabel.bottomAnchor.constraint(equalTo: leftColumn.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 9),
            divider.topAnchor.constraint(equalTo: contentStack.topAnchor),
            divider.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            leftColumn.topAnchor.constraint(equalTo: contentStack.topAnchor),
            leftColumn.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor),
            detail.topAnchor.constraint(equalTo: contentStack.topAnchor),
            detail.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor),
            detailIcon.widthAnchor.constraint(equalToConstant: 16),
            detailIcon.heightAnchor.constraint(equalToConstant: 16),
            header.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 2),
            header.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            header.topAnchor.constraint(equalTo: detail.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            body.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            // 详情在自己的栏内避开底部操作按钮，不影响左侧列表和面板高度。
            body.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -26),

            detailTextScroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            detailTextScroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            detailTextScroll.topAnchor.constraint(equalTo: body.topAnchor),
            detailTextScroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            detailImage.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            detailImage.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            detailImage.topAnchor.constraint(equalTo: body.topAnchor),
            detailImage.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            detailEmpty.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            detailEmpty.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            detailEmpty.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -20)
        ])
        controls.isHidden = true
    }

    /// 自检用：按行号选中一条，触发右侧展开。
    func selectRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    /// 自检用：清空选择，回到收起态。
    func clearSelection() {
        table.deselectAll(nil)
        updateColumns()
    }

    /// 自检用：右下操作按钮行是否可见。
    var isControlRowVisible: Bool { !controls.isHidden }
    var layoutFrame: NSRect { panel.frame }
    var layoutDiagnostics: String {
        guard let root = panel.contentView else { return "no root" }
        return "panel=\(panel.frame) selected=\(table.selectedRow) left=\(leftColumn.frame) detail=\(detail.frame) count=\(countLabel.convert(countLabel.bounds, to: root)) controls=\(controls.convert(controls.bounds, to: root)) preview=\(detailTextScroll.convert(detailTextScroll.bounds, to: root))"
    }

    func validateLayout() -> Bool {
        panel.contentView?.layoutSubtreeIfNeeded()
        guard panel.frame.width <= 645, search.frame.width > 200,
              (table.enclosingScrollView?.frame.height ?? 0) >= 60, table.rowHeight <= 32
        else { return false }
        if !controls.isHidden {
            guard let root = panel.contentView else { return false }
            let countFrame = countLabel.convert(countLabel.bounds, to: root)
            let controlsFrame = controls.convert(controls.bounds, to: root)
            let previewFrame = detailTextScroll.convert(detailTextScroll.bounds, to: root)
            guard abs(countFrame.midY - controlsFrame.midY) <= 1,
                  controlsFrame.minY >= 4,
                  controlsFrame.minX >= countFrame.maxX,
                  previewFrame.minY >= controlsFrame.maxY else { return false }
        }
        if detail.isHidden { return abs(leftColumn.frame.width - contentStack.frame.width) <= 2 }
        return abs(leftColumn.frame.width - detail.frame.width) <= 2 && detail.frame.width >= 240
    }

    func show() {
        if panel.isVisible { closePanel(); return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier { previousApp = nil }
        history.query = ""
        search.stringValue = ""
        table.deselectAll(nil)
        reload()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        fitTable()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(search)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
               let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let number = Int(chars), (1...9).contains(number) {
                self.copyNumber(number)
                return nil
            }
            switch event.keyCode {
            case 53: self.closePanel(); return nil
            case 125: self.move(1); return nil
            case 126: self.move(-1); return nil
            case 36, 76: self.copySelection(); return nil
            default: return event
            }
        }
    }

    @objc private func closePanel() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panel.orderOut(nil)
    }
    func windowDidResignKey(_ notification: Notification) {
        if suppressClose || panel.attachedSheet != nil { return }
        closePanel()
    }
    func windowDidResize(_ notification: Notification) { fitTable() }
    func controlTextDidChange(_ obj: Notification) { history.query = search.stringValue; reload() }

    private func fitPanelHeight() {
        // 顶部搜索框与底部计数区；按钮共享计数区，选中前后高度一致。
        let chrome: CGFloat = 72
        let tableHeight = rows.reduce(0) { $0 + Self.rowHeight(for: $1) }
        let limit = (NSScreen.main?.visibleFrame.height ?? 900) - 120
        let desired = max(220, min(chrome + tableHeight, min(560, limit)))
        var frame = panel.frame
        guard abs(frame.height - desired) > 0.5 else { return }
        let top = frame.maxY
        frame.size.height = desired
        frame.origin.y = top - desired
        panel.setFrame(frame, display: false)
    }

    private func fitTable() {
        guard let clip = table.enclosingScrollView?.contentView else { return }
        var frame = table.frame
        frame.size.width = clip.bounds.width
        table.frame = frame
        table.sizeLastColumnToFit()
    }

    private func reload() {
        let selected = selectedEntry?.id
        rows = Self.displayedRows(from: history.filtered, limit: history.maxVisible, searching: !history.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        fitPanelHeight()
        fitTable()
        table.reloadData()
        countLabel.stringValue = rows.isEmpty ? "还没有记录。复制文字或图片后会自动出现在这里。" : "\(rows.count) 项 · \(history.storage.title)"
        if let index = selected.flatMap({ id in rows.firstIndex(where: { $0.id == id }) }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        updateColumns()
        updatePreview()
    }
    private func updateColumns() {
        let expanded = selectedEntry != nil
        detail.isHidden = !expanded
        divider.isHidden = !expanded
        let shown = NSStackView.VisibilityPriority(rawValue: 100)
        contentStack.setVisibilityPriority(expanded ? shown : .notVisible, for: detail)
        controls.isHidden = !expanded
        panel.contentView?.layoutSubtreeIfNeeded()
        fitTable()
    }

    private var selectedEntry: ClipboardEntry? {
        guard rows.indices.contains(table.selectedRow) else { return nil }
        return rows[table.selectedRow]
    }
    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        if table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: delta > 0 ? 0 : rows.count - 1), byExtendingSelection: false)
            table.scrollRowToVisible(table.selectedRow)
            return
        }
        let next = max(0, min(rows.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        var views: [NSView] = []

        if entry.png != nil, let image = entry.image {
            // 图片行：直接给缩略图，而不是“图片”两个字。
            let thumb = NSImageView()
            thumb.image = image
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = 4
            thumb.layer?.masksToBounds = true
            thumb.layer?.borderWidth = 1
            thumb.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.widthAnchor.constraint(equalToConstant: 38).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: 38).isActive = true
            views.append(thumb)
            let size = NSTextField(labelWithString: "\(Int(image.size.width)) × \(Int(image.size.height))")
            size.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            size.textColor = .secondaryLabelColor
            size.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(size)
        } else {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let title = NSTextField(labelWithString: (entry.pinned ? "置顶 · " : "") + entry.title)
            title.lineBreakMode = .byTruncatingTail
            title.font = .systemFont(ofSize: 12)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(icon)
            views.append(title)
        }

        let badge = NSTextField(labelWithString: Self.badge(for: entry, number: number(forRow: row)))
        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        badge.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        badge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        badge.isHidden = badge.stringValue.isEmpty
        views.append(badge)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 8)
        return stack
    }

    static func rowHeight(for entry: ClipboardEntry) -> CGFloat { entry.png != nil ? 46 : 30 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) ? Self.rowHeight(for: rows[row]) : 30
    }

    /// 置顶条目只显示自己配置的快捷键，不占 ⌘1–⌘9；非置顶按显示顺序编号。
    static func badge(for entry: ClipboardEntry, number: Int?) -> String {
        if let label = entry.shortcutLabel { return label }
        guard !entry.pinned, let number, (1...9).contains(number) else { return "" }
        return "⌘\(number)"
    }

    static func displayedRows(from filtered: [ClipboardEntry], limit: Int, searching: Bool) -> [ClipboardEntry] {
        let pinned = filtered.filter(\.pinned)
        guard !searching else { return filtered }
        return pinned + filtered.filter { !$0.pinned }.prefix(ClipboardHistory.clampedVisible(limit))
    }

    private func number(forRow row: Int) -> Int? {
        guard rows.indices.contains(row), !rows[row].pinned else { return nil }
        let index = rows.prefix(row).filter { !$0.pinned }.count
        return index < 9 ? index + 1 : nil
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardRowView()
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateColumns()
        updatePreview()
    }

    /// 离屏渲染浮层，用于视觉自检：选中首条命中记录后把面板画成 PNG。
    func snapshot(to path: String, selectImage: Bool) -> Bool {
        reload()
        panel.contentView?.layoutSubtreeIfNeeded()
        fitTable()
        let index = rows.firstIndex { selectImage ? $0.png != nil : $0.png == nil }
        if let index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            updatePreview()
        }
        return writeSnapshot(to: path)
    }

    /// 未选中任何条目（收起态）时的浮层截图。
    func snapshotCollapsed(to path: String) -> Bool {
        reload()
        clearSelection()
        panel.contentView?.layoutSubtreeIfNeeded()
        fitTable()
        return writeSnapshot(to: path)
    }

    private func writeSnapshot(to path: String) -> Bool {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
    private func updatePreview() {
        guard let entry = selectedEntry else {
            detailIcon.image = nil
            detailSource.stringValue = "未选中记录"
            detailMeta.stringValue = ""
            detailText.string = ""
            detailTextScroll.isHidden = true
            detailImage.image = nil
            detailImage.isHidden = true
            detailEmpty.isHidden = false
            return
        }
        detailEmpty.isHidden = true
        detailSource.stringValue = entry.source.isEmpty ? "剪贴板" : entry.source
        detailIcon.image = Self.sourceIcon(entry.source)
        detailMeta.stringValue = Self.detailMeta(entry)
        if let png = entry.png {
            detailImage.image = NSImage(data: png)
            detailImage.isHidden = false
            detailTextScroll.isHidden = true
            detailText.string = ""
        } else {
            detailText.string = entry.text ?? ""
            detailTextScroll.isHidden = false
            detailImage.image = nil
            detailImage.isHidden = true
            detailText.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    private static func detailMeta(_ entry: ClipboardEntry) -> String {
        var parts: [String] = []
        if entry.kind == .image {
            parts.append("图片")
            if let png = entry.png, let rep = NSBitmapImageRep(data: png) {
                parts.append("\(rep.pixelsWide)×\(rep.pixelsHigh)")
            }
        } else {
            parts.append("\(entry.text?.count ?? 0) 字")
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
        if entry.pinned { parts.append("已置顶") }
        if let label = entry.shortcutLabel { parts.append("快捷键 " + label) }
        let date = Date(timeIntervalSince1970: entry.copiedAt)
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        parts.append(formatter.string(from: date))
        return parts.joined(separator: " · ")
    }

    private static func sourceIcon(_ source: String) -> NSImage? {
        guard !source.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == source })?.icon
    }
    @objc private func pinSelection() {
        guard let entry = selectedEntry else { return }
        history.togglePin(entry); reload()
    }
    @objc private func deleteSelection() {
        guard let entry = selectedEntry else { return }
        history.delete(entry); reload()
    }
    private func copyNumber(_ number: Int) {
        guard let index = rows.indices.first(where: { self.number(forRow: $0) == number }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        copySelection()
    }

    func menuWillOpen(_ menu: NSMenu) { suppressClose = true }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            self?.suppressClose = false
            if let self, self.panel.isVisible { self.panel.makeKeyAndOrderFront(nil) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        suppressClose = true
        if table.clickedRow >= 0 { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
        let entry = selectedEntry
        for item in menu.items {
            switch item.title {
            case "清除快捷键": item.isEnabled = entry?.shortcutLabel != nil
            case "指定快捷键…": item.isEnabled = entry != nil
            default: item.isEnabled = entry != nil
            }
        }
    }

    @objc private func assignShortcut() {
        guard let entry = selectedEntry else { return }
        presentRecorder(for: entry)
    }

    @objc private func clearShortcut() {
        guard let entry = selectedEntry else { return }
        history.setShortcut(entry, key: nil, modifiers: nil)
        reload()
    }

    private func presentRecorder(for entry: ClipboardEntry) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 128),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "指定快捷键"
        let content = NSView()
        window.contentView = content

        let preview = NSTextField(labelWithString: entry.title)
        preview.font = .systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        let hint = NSTextField(labelWithString: "按下想要的组合键（需含 ⌘、⌃ 或 ⌥；Backspace 清除；Esc 取消）")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        let keys = NSTextField(labelWithString: entry.shortcutLabel ?? "等待按键…")
        keys.font = .systemFont(ofSize: 20, weight: .semibold)
        keys.alignment = .center
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 10)
        status.textColor = .systemRed
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail

        for view in [preview, hint, keys, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 4),
            keys.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            keys.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            keys.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: keys.bottomAnchor, constant: 4)
        ])

        let capture = ShortcutCaptureView()
        capture.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(capture)
        NSLayoutConstraint.activate([
            capture.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            capture.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            capture.topAnchor.constraint(equalTo: content.topAnchor),
            capture.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        capture.onKey = { [weak self, weak window] event in
            guard let self, let window else { return }
            let closing = self.handleRecorderKey(event, entry: entry, keys: keys, status: status)
            if closing {
                self.panel.endSheet(window)
                window.orderOut(nil)
                self.reload()
            }
        }
        panel.beginSheet(window) { _ in }
        window.makeFirstResponder(capture)
        DispatchQueue.main.async { window.makeFirstResponder(capture) }
    }

    /// 返回 true 表示可以关闭录制窗口。
    func handleRecorderKey(_ event: NSEvent, entry: ClipboardEntry,
                                   keys: NSTextField, status: NSTextField) -> Bool {
        let keyCode = event.keyCode
        if keyCode == 53 { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [String] = []
        if flags.contains(.control) { modifiers.append("control") }
        if flags.contains(.option) { modifiers.append("option") }
        if flags.contains(.shift) { modifiers.append("shift") }
        if flags.contains(.command) { modifiers.append("command") }
        if keyCode == 51 {   // Backspace 清除
            history.setShortcut(entry, key: nil, modifiers: nil)
            return true
        }
        guard let key = KeyCodes.name(for: keyCode), !modifiers.isEmpty,
              modifiers.contains(where: { $0 != "shift" }) else {
            status.stringValue = "需要至少一个 ⌘、⌃ 或 ⌥ 修饰键"
            return false
        }
        let label = KeyCodes.display(modifiers) + KeyCodes.keyLabel(key)
        keys.stringValue = label
        // 保留组合键与面板内 ⌘1–⌘9 不能被占用。
        let reserved = [["option"], ["command", "option"]]
        if reserved.contains(where: { Set($0) == Set(modifiers) }) && (key == "space" || key == "k" || key == ",") {
            status.stringValue = "\(label) 已被 MacKit 的其它快捷键占用"
            return false
        }
        if modifiers == ["command"], ["1", "2", "3", "4", "5", "6", "7", "8", "9"].contains(key) {
            status.stringValue = "\(label) 与面板内的数字快捷键冲突"
            return false
        }
        if history.entries.contains(where: { $0.id != entry.id && $0.shortcutKey == key && Set($0.shortcutModifiers ?? []) == Set(modifiers) }) {
            status.stringValue = "\(label) 已分配给其它记录"
            return false
        }
        history.setShortcut(entry, key: key, modifiers: modifiers)
        status.stringValue = ""
        return true
    }

    @objc private func copySelection() {
        if selectedEntry == nil, !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        guard let entry = selectedEntry, history.copy(entry) else { return }
        let target = previousApp
        closePanel()
        if let target, !target.isTerminated { target.activate(options: [.activateIgnoringOtherApps]) }
        // 自动粘贴仅在用户主动启用并已授予辅助功能权限时执行。
        guard history.autoPaste, let target, AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.postToPid(target.processIdentifier); up?.postToPid(target.processIdentifier)
        }
    }
}

private final class ClipboardRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 2, dy: 1.5)
        let color = isEmphasized ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.28)
        color.withAlphaComponent(isEmphasized ? 0.85 : 0.35).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}

private final class ShortcutCaptureView: NSView {
    var onKey: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func mouseDown(with event: NSEvent) { onCancel?() }
}

/// 设置页里用的按键捕获层：出现即取得第一响应者。
private struct KeyCaptureLayer: NSViewRepresentable {
    let onKey: (NSEvent) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onKey = onKey
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {
        nsView.onKey = onKey
        nsView.onCancel = onCancel
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let window = nsView.window, window.firstResponder !== nsView else { return }
            window.makeFirstResponder(nsView)
        }
    }
}

// MARK: - 主界面剪贴板页

/// 设置页里置顶条目的快捷键规则：⌘ + 一个字母或数字。
enum PinnedShortcutResult: Equatable {
    case assigned
    case cleared
    case cancelled
    case rejected(String)
}

enum PinnedShortcut {
    static func handle(_ event: NSEvent, entry: ClipboardEntry, history: ClipboardHistory) -> PinnedShortcutResult {
        switch event.keyCode {
        case 53: return .cancelled
        case 51:
            history.setShortcut(entry, key: nil, modifiers: nil)
            return .cleared
        default: break
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        guard flags == [.command] else {
            return .rejected("只支持 ⌘ + 字母或数字（不带其它修饰键）")
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
              let scalar = chars.unicodeScalars.first,
              CharacterSet.lowercaseLetters.union(.decimalDigits).contains(scalar) else {
            return .rejected("只支持 ⌘ + 字母或数字")
        }
        if history.entries.contains(where: {
            $0.id != entry.id && $0.shortcutKey == chars && Set($0.shortcutModifiers ?? []) == ["command"]
        }) {
            return .rejected("⌘\(chars.uppercased()) 已分配给其它记录")
        }
        history.setShortcut(entry, key: chars, modifiers: ["command"])
        return .assigned
    }
}

final class PinnedShortcutState: ObservableObject {
    @Published var recordingID: String?
    @Published var message = ""
}

struct ClipboardSettingsPage: View {
    @ObservedObject var history: ClipboardHistory
    @ObservedObject private var recorder = PinnedShortcutState()

    private var pinnedEntries: [ClipboardEntry] { history.entries.filter { $0.pinned } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("保存方式")
                Spacer()
                Picker("保存方式", selection: Binding(get: { history.storage }, set: { history.chooseStorage($0) })) {
                    ForEach(ClipboardStorage.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden().frame(width: 155)
            }
            Text(history.storageNote).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("列表显示条数（不含置顶）")
                Spacer()
                Stepper(value: Binding(get: { history.maxVisible }, set: { history.setMaxVisible($0) }), in: 1...20) {
                    Text("\(history.maxVisible) 条").font(.system(size: 11)).monospacedDigit()
                }
                .controlSize(.small)
            }
            Text("非置顶按顺序使用 ⌘1–⌘9；置顶不占编号，可单独绑定。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !pinnedEntries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("置顶快捷键").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("⌘ + 字母或数字").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ForEach(pinnedEntries) { item in
                        HStack(spacing: 8) {
                            if item.png != nil, let image = item.image {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 22, height: 22)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Image(systemName: "pin.fill").frame(width: 22)
                            }
                            Text(item.title).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 8)
                            if recorder.recordingID == item.id {
                                Text("按下 ⌘ + 字母/数字…").font(.system(size: 11)).foregroundStyle(.secondary)
                            } else if let label = item.shortcutLabel {
                                Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                Button {
                                    history.setShortcut(item, key: nil, modifiers: nil)
                                    recorder.message = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.plain).help("清除这个快捷键")
                            } else {
                                Button("设置") { startRecording(item) }.controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
                    }
                    if !recorder.message.isEmpty {
                        Text(recorder.message).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
                .padding(.top, 2)
                .overlay {
                    if recorder.recordingID != nil {
                        KeyCaptureLayer(onKey: { handleRecordKey($0) }, onCancel: {
                            recorder.recordingID = nil
                        })
                        .background(Color.black.opacity(0.001))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { recorder.recordingID = nil }
                    }
                }
            }
            if history.storage == .iCloud {
                HStack {
                    Text(history.cloudFolder).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("立即同步") { history.syncNow() }
                    Button("选择文件夹…") { history.chooseCloudFolder() }
                }.font(.system(size: 10))
            }
            HStack(spacing: 18) {
                HStack {
                    Text("暂停记录")
                    Spacer(minLength: 4)
                    GlassSwitch(isOn: Binding(get: { history.paused }, set: { history.setPaused($0) }))
                }.frame(maxWidth: .infinity)
                HStack {
                    Text("自动粘贴")
                    Spacer(minLength: 4)
                    GlassSwitch(isOn: Binding(get: { history.autoPaste }, set: { history.setAutoPaste($0) }))
                }.frame(maxWidth: .infinity)
            }
            .padding(.vertical, 2)
            Text("自动粘贴需辅助功能权限；未授权可手动 ⌘V，默认关闭。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if history.autoPaste && !AXIsProcessTrusted() {
                Button("打开辅助功能设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }.controlSize(.small)
            }
            Divider().padding(.vertical, 3)
            HStack {
                Text("历史记录 · \(history.entries.count) 项").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("清空历史") { history.showClearConfirmation = true }
                    .controlSize(.small).disabled(history.entries.isEmpty)
            }
            TextField("搜索历史", text: $history.query).textFieldStyle(.roundedBorder)
            LazyVStack(spacing: 4) {
                        if history.filtered.isEmpty {
                            Text("复制文字或图片后，会自动记录在这里。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 20)
                        }
                        ForEach(history.filtered) { item in
                            HStack(spacing: 8) {
                                Button {
                                    _ = history.copy(item)
                                } label: {
                                    HStack(spacing: 8) {
                                        if let png = item.png, let image = NSImage(data: png) {
                                            Image(nsImage: image).resizable().scaledToFit().frame(width: 24, height: 24)
                                        } else {
                                            Image(systemName: item.pinned ? "pin.fill" : "doc.on.clipboard").frame(width: 24)
                                        }
                                        Text(item.title).font(.system(size: 11)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).help("复制这条记录")
                                Button { history.togglePin(item) } label: {
                                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                                }.buttonStyle(.plain).help("置顶或取消置顶")
                                Button { history.delete(item) } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.plain).help("删除记录")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
                            .id(item.id)
                        }
            }
            Text("最多保留 200 项 / 24 MB").font(.system(size: 10)).foregroundStyle(.tertiary)
            if !history.status.isEmpty {
                Text(history.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12))
        .alert("清空剪贴板历史？", isPresented: $history.showClearConfirmation) {
            Button("清空", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包括置顶项，清空后无法恢复。iCloud 模式也会同步删除这些记录；系统当前剪贴板不受影响。")
        }
    }

    private func startRecording(_ entry: ClipboardEntry) {
        recorder.message = ""
        recorder.recordingID = entry.id
    }

    /// 设置页录制：只接受 ⌘ + 一个字母或数字。
    private func handleRecordKey(_ event: NSEvent) {
        guard let id = recorder.recordingID, let entry = history.entries.first(where: { $0.id == id }) else {
            recorder.recordingID = nil
            return
        }
        switch PinnedShortcut.handle(event, entry: entry, history: history) {
        case .assigned, .cleared:
            recorder.recordingID = nil
            recorder.message = ""
        case .cancelled:
            recorder.recordingID = nil
        case .rejected(let message):
            recorder.message = message
        }
    }
}

// MARK: - 隔离自检

/// 公开文档的模拟内容；不读取系统剪贴板、个人历史或任何配置文件。
func makeDemoClipboardHistory() -> ClipboardHistory {
    let suite = "MacKit-Demo-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let board = NSPasteboard(name: NSPasteboard.Name(suite))
    let history = ClipboardHistory(defaults: defaults, board: board)
    let examples = ["常用项目链接", "hello@example.com", "会议纪要：确认需求，完成验证", "https://example.com/docs", "本周待办：整理项目与发布说明", "一段刚刚复制的文字"]
    for (index, text) in examples.enumerated() {
        let entry = ClipboardEntry.make(text: text, source: "示例", now: Date().timeIntervalSince1970 - Double(index * 60))!
        history.insert(entry)
        if index < 2 {
            history.togglePin(entry)
            history.setShortcut(entry, key: index == 0 ? "m" : "s", modifiers: ["command"])
        }
    }
    return history
}

func runClipboardSnapshot() -> Never {
    let args = CommandLine.arguments
    guard let flag = args.firstIndex(of: "--clipboard-snapshot"), flag + 1 < args.count else {
        print("用法: --clipboard-snapshot <输出目录>")
        exit(2)
    }
    let outDir = URL(fileURLWithPath: args[flag + 1])
    _ = NSApplication.shared
    let suite = "MacKit-Snapshot-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let board = NSPasteboard(name: NSPasteboard.Name("MacKit-Snapshot-\(UUID().uuidString)"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacKit-Snapshot-\(UUID().uuidString)")
    defer {
        defaults.removePersistentDomain(forName: suite)
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
    let history = ClipboardHistory(defaults: defaults, board: board, localURL: root.appendingPathComponent("history.json"))

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 640, height: 400).fill()
    NSColor.black.withAlphaComponent(0.25).setFill()
    NSRect(x: 40, y: 40, width: 560, height: 120).fill()
    NSGraphicsContext.restoreGraphicsState()

    history.insert(ClipboardEntry.make(text: String(repeating: "侧栏详情测试：", count: 12) + "末尾标记 END", now: Date().timeIntervalSince1970 + 3)!)
    history.insert(ClipboardEntry.make(png: bitmap.representation(using: .png, properties: [:])!, now: Date().timeIntervalSince1970 + 2)!)
    history.insert(ClipboardEntry.make(text: "常用项目链接", now: Date().timeIntervalSince1970 + 1)!)
    if let pinned = history.entries.first(where: { $0.text == "常用项目链接" }) { history.togglePin(pinned) }

    let controller = ClipboardPanelController(history: history)
    let text = outDir.appendingPathComponent("clipboard-text.png").path
    let image = outDir.appendingPathComponent("clipboard-image.png").path
    let collapsed = outDir.appendingPathComponent("clipboard-collapsed.png").path
    let ok = controller.snapshot(to: text, selectImage: false)
        && controller.snapshot(to: image, selectImage: true)
        && controller.snapshotCollapsed(to: collapsed)
    print(ok ? "✓ 已输出 \(text)、\(image) 与 \(collapsed)" : "✗ 快照失败")
    exit(ok ? 0 : 1)
}

func runClipboardCheck() -> Never {
    _ = NSApplication.shared
    let board = NSPasteboard(name: NSPasteboard.Name("MacKit-Test-\(UUID().uuidString)"))
    let suite = "MacKit-Test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacKit-Clipboard-Test-\(UUID().uuidString)")
    let local = root.appendingPathComponent("history.json")
    defer {
        defaults.removePersistentDomain(forName: suite)
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
    var success = false
    var stage = "start"
    do {
        let history = ClipboardHistory(defaults: defaults, board: board, localURL: local)
        guard history.storage == .memory, !history.autoPaste else { throw ClipboardError.invalidArchive }
        stage = "insert1"
        history.insert(ClipboardEntry.make(text: "测试文本", now: 100)!)
        guard !FileManager.default.fileExists(atPath: local.path) else { throw ClipboardError.invalidArchive }
        history.insert(ClipboardEntry.make(text: "测试文本", now: 200)!)
        guard history.entries.count == 1, history.entries.first?.copiedAt == 200 else { throw ClipboardError.invalidArchive }
        let first = history.entries[0]
        history.togglePin(first)
        guard history.entries[0].pinned else { throw ClipboardError.invalidArchive }
        history.query = "测试"
        guard history.filtered.count == 1 else { throw ClipboardError.invalidArchive }
        history.query = "无匹配"
        guard history.filtered.isEmpty else { throw ClipboardError.invalidArchive }
        let searchable = ClipboardEntry.make(text: String(repeating: "a", count: 250) + "全文末尾查找", now: 250)!
        history.insert(searchable)
        history.query = "全文末尾查找"
        guard history.filtered.count == 1 else { throw ClipboardError.invalidArchive }
        history.delete(searchable)
        history.query = ""
        board.clearContents()
        board.setString("password fixture", forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        guard ClipboardHistory.capture(board) == nil else { throw ClipboardError.invalidArchive }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        let image = ClipboardEntry.make(png: png, now: 300)!
        board.clearContents()
        board.setData(png, forType: .png)
        guard ClipboardHistory.capture(board)?.kind == .image else { throw ClipboardError.invalidArchive }
        history.insert(image)
        stage = "local-storage"
        history.chooseStorage(.local)
        guard history.storage == .local, FileManager.default.fileExists(atPath: local.path) else { throw ClipboardError.invalidArchive }
        // 自定义快捷键：写入、落盘、徽标编号与同内容复制后保留。
        guard let shortcutEntry = history.entries.first else { throw ClipboardError.invalidArchive }
        history.setShortcut(shortcutEntry, key: "m", modifiers: ["command"])
        guard history.entry(id: shortcutEntry.id)?.shortcutLabel == "⌘M" else { throw ClipboardError.invalidArchive }
        let shortcutDisk = try JSONDecoder().decode(ClipboardArchive.self, from: Data(contentsOf: local)).validated()
        guard shortcutDisk.entries.contains(where: { $0.shortcutKey == "m" && $0.shortcutModifiers == ["command"] }) else { throw ClipboardError.invalidArchive }
        let numbered = ClipboardEntry.make(text: "编号", now: 1)!
        var pinnedSample = ClipboardEntry.make(text: "置顶样本", now: 2)!
        pinnedSample.pinned = true
        guard ClipboardPanelController.badge(for: history.entry(id: shortcutEntry.id)!, number: 1) == "⌘M",
              ClipboardPanelController.badge(for: numbered, number: 5) == "⌘5",
              ClipboardPanelController.badge(for: numbered, number: 10) == "",
              ClipboardPanelController.badge(for: numbered, number: nil) == "",
              ClipboardPanelController.badge(for: pinnedSample, number: 1) == "" else { throw ClipboardError.invalidArchive }
        // 置顶不占编号、非置顶按显示顺序编号，显示条数可设置
        let listing = [pinnedSample, numbered] + (1...5).map { ClipboardEntry.make(text: "行 \($0)", now: Double($0 + 2))! }
        let shown = ClipboardPanelController.displayedRows(from: listing, limit: 3, searching: false)
        guard shown.count == 4, shown.first?.pinned == true,
              ClipboardPanelController.displayedRows(from: listing, limit: 3, searching: true).count == listing.count,
              ClipboardPanelController.displayedRows(from: listing, limit: 1, searching: false).count == 2 else { throw ClipboardError.invalidArchive }
        history.setMaxVisible(0)
        guard history.maxVisible == 1 else { throw ClipboardError.invalidArchive }
        history.setMaxVisible(99)
        guard history.maxVisible == 30 else { throw ClipboardError.invalidArchive }
        history.setMaxVisible(9)
        guard history.maxVisible == 9 else { throw ClipboardError.invalidArchive }
        history.insert(ClipboardEntry.make(text: shortcutEntry.text ?? "", now: 400)!)
        guard history.entry(id: shortcutEntry.id)?.shortcutLabel == "⌘M" else { throw ClipboardError.invalidArchive }
        history.setShortcut(history.entry(id: shortcutEntry.id)!, key: nil, modifiers: nil)
        guard history.entry(id: shortcutEntry.id)?.shortcutLabel == nil else { throw ClipboardError.invalidArchive }
        history.setShortcut(shortcutEntry, key: "m", modifiers: ["command"])
        stage = "shortcut-block"
        let restored = try JSONDecoder().decode(ClipboardArchive.self, from: Data(contentsOf: local)).validated()
        guard restored.entries.count == 2, restored.entries.contains(where: { $0.kind == .image }) else { throw ClipboardError.invalidArchive }
        var remote = restored
        remote.deleted[image.id] = Date().timeIntervalSince1970
        guard !ClipboardArchive.merge(restored, remote).entries.contains(where: { $0.id == image.id }) else { throw ClipboardError.invalidArchive }
        var cleared = restored
        cleared.clearedAt = Date().timeIntervalSince1970
        cleared.entries = []
        guard ClipboardArchive.merge(restored, cleared).entries.isEmpty else { throw ClipboardError.invalidArchive }
        stage = "merge-checks"
        history.chooseStorage(.memory)
        guard history.storage == .memory, !history.autoPaste else { throw ClipboardError.invalidArchive }
        let many = (1...300).map { ClipboardEntry.make(text: "item \($0)", now: Double($0))! }
        guard ClipboardArchive.bounded(many).count == 200 else { throw ClipboardError.invalidArchive }
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        history.setCloudFolder(cloud)
        guard history.storage == .iCloud else { throw ClipboardError.invalidArchive }
        let otherSuite = suite + "-other"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let other = ClipboardHistory(defaults: otherDefaults, board: board, localURL: root.appendingPathComponent("other.json"))
        other.setCloudFolder(cloud)
        guard other.entries.count == history.entries.count else { throw ClipboardError.invalidArchive }
        other.insert(ClipboardEntry.make(text: "另一设备记录", now: Date().timeIntervalSince1970)!)
        history.syncNow()
        guard history.entries.contains(where: { $0.text == "另一设备记录" }) else { throw ClipboardError.invalidArchive }
        history.clear()
        other.syncNow()
        guard other.entries.isEmpty else { throw ClipboardError.invalidArchive }
        guard history.copy(first), board.string(forType: .string) == first.text,
              ClipboardHistory.capture(board) == nil else { throw ClipboardError.invalidArchive }
        // 读取损坏文件不得覆盖；符号链接不得写入。
        let corrupted = root.appendingPathComponent("corrupt.json")
        try Data("bad-json".utf8).write(to: corrupted)
        let badDefaults = UserDefaults(suiteName: suite + "-bad")!
        defer { badDefaults.removePersistentDomain(forName: suite + "-bad") }
        let bad = ClipboardHistory(defaults: badDefaults, board: board, localURL: corrupted)
        bad.chooseStorage(.local)
        guard bad.storage == .memory, try String(contentsOf: corrupted, encoding: .utf8) == "bad-json" else { throw ClipboardError.invalidArchive }
        let symlink = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: corrupted)
        let linked = ClipboardHistory(defaults: badDefaults, board: board, localURL: symlink)
        linked.chooseStorage(.local)
        guard linked.storage == .memory else { throw ClipboardError.invalidArchive }
        stage = "controller"
        // 加足列表高度，避免 220pt 最小高度掩盖选中后额外增高的问题。
        let layoutTime = Date().timeIntervalSince1970 + 10
        let layoutFixtures = (1...8).map { ClipboardEntry.make(text: "布局测试 \($0)", now: layoutTime + Double($0))! }
        layoutFixtures.forEach { history.insert($0) }
        let controller = ClipboardPanelController(history: history)
        let collapsedFrame = controller.layoutFrame
        controller.selectRow(0)
        guard controller.validateLayout(), controller.isControlRowVisible,
              controller.layoutFrame == collapsedFrame else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "浮层布局断言失败（展开态，按钮不得增加高度）：\(controller.layoutDiagnostics) initial=\(collapsedFrame)"])
        }
        controller.clearSelection()
        guard controller.validateLayout(), !controller.isControlRowVisible,
              controller.layoutFrame == collapsedFrame else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "浮层布局断言失败（收起态）"])
        }
        layoutFixtures.forEach { history.delete($0) }
        var layoutImage = image
        layoutImage.copiedAt = layoutTime + 20
        history.insert(layoutImage)
        let imageController = ClipboardPanelController(history: history)
        let imageFrame = imageController.layoutFrame
        imageController.selectRow(0)
        guard imageController.validateLayout(), imageController.isControlRowVisible,
              imageController.layoutFrame == imageFrame else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "图片预览不得撑大浮层：\(imageController.layoutDiagnostics)"])
        }
        history.delete(layoutImage)
        // 录制面板按键处理：合法组合写入、重复与保留键被拒。
        history.chooseStorage(.local)
        history.insert(ClipboardEntry.make(text: "录制测试 A", now: 500)!)
        history.insert(ClipboardEntry.make(text: "录制测试 B", now: 501)!)
        let labelField = NSTextField(labelWithString: "")
        let statusField = NSTextField(labelWithString: "")
        func keyEvent(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        guard let target = history.entries.first else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "无可用测试条目"])
        }
        let okKey = controller.handleRecorderKey(keyEvent(46, [.command], "m"), entry: target, keys: labelField, status: statusField)
        let gotLabel = history.entry(id: target.id)?.shortcutLabel ?? "nil"
        guard okKey, gotLabel == "⌘M" else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "录制写入失败 ok=\(okKey) label=\(gotLabel) status=\(statusField.stringValue)"])
        }
        guard let another = history.entries.dropFirst().first else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少第二条测试条目"])
        }
        let dup = controller.handleRecorderKey(keyEvent(46, [.command], "m"), entry: another, keys: labelField, status: statusField)
        guard !dup, !statusField.stringValue.isEmpty else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "重复快捷键未被拒绝"])
        }
        let reserved = controller.handleRecorderKey(keyEvent(49, [.option], " "), entry: another, keys: labelField, status: statusField)
        guard !reserved, history.entry(id: another.id)?.shortcutLabel == nil else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "保留快捷键未被拒绝 st=\(statusField.stringValue)"])
        }
        history.setShortcut(history.entry(id: target.id)!, key: nil, modifiers: nil)
        // 全局快捷键注册的最小烟囱测试（用不冲突的组合并立即注销）。
        var ref: EventHotKeyRef?
        let probe = EventHotKeyID(signature: OSType(0x4D4B5453), id: 0xE1FF)
        let probeStatus = RegisterEventHotKey(UInt32(KeyCodes.map["f13"] ?? 105), UInt32(cmdKey | optionKey | controlKey | shiftKey),
                                              probe, GetApplicationEventTarget(), 0, &ref)
        guard probeStatus == noErr, let ref else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "Carbon 注册失败 status=\(probeStatus)"])
        }
        UnregisterEventHotKey(ref)
        // 设置页置顶快捷键：只收 ⌘ + 单个字母/数字，冲突与组合键要拒绝。
        var pinA = ClipboardEntry.make(text: "置顶 A", now: 600)!
        pinA.pinned = true
        history.insert(pinA)
        var pinB = ClipboardEntry.make(text: "置顶 B", now: 601)!
        pinB.pinned = true
        history.insert(pinB)
        guard let a = history.entries.first(where: { $0.text == "置顶 A" }),
              let b = history.entries.first(where: { $0.text == "置顶 B" }) else { throw ClipboardError.invalidArchive }
        func expect(_ result: PinnedShortcutResult, _ event: NSEvent, _ entry: ClipboardEntry, _ name: String) throws {
            guard PinnedShortcut.handle(event, entry: entry, history: history) == result else {
                throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "置顶快捷键断言失败：\(name)"])
            }
        }
        try expect(.assigned, keyEvent(46, [.command], "m"), a, "⌘M 写入")
        guard history.entry(id: a.id)?.shortcutLabel == "⌘M" else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "⌘M 未保存"])
        }
        try expect(.rejected("⌘M 已分配给其它记录"), keyEvent(46, [.command], "m"), b, "重复组合")
        try expect(.rejected("只支持 ⌘ + 字母或数字（不带其它修饰键）"), keyEvent(40, [.command, .shift], "k"), b, "⌘⇧K 被拒")
        try expect(.rejected("只支持 ⌘ + 字母或数字（不带其它修饰键）"), keyEvent(46, [.command, .control], "m"), b, "⌘⌃M 被拒")
        try expect(.rejected("只支持 ⌘ + 字母或数字"), keyEvent(49, [.command], " "), b, "⌘Space 被拒")
        try expect(.assigned, keyEvent(18, [.command], "1"), b, "⌘1 允许")
        guard history.entry(id: b.id)?.shortcutLabel == "⌘1" else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "⌘1 未保存"])
        }
        try expect(.cleared, keyEvent(51, [.command], "\u{8}"), b, "退格清除")
        guard history.entry(id: b.id)?.shortcutLabel == nil else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "退格未清除"])
        }
        try expect(.cancelled, keyEvent(53, [], "\u{1b}"), a, "Esc 取消")
        print("✓ 默认不落盘、去重、搜索、置顶、私密过滤、图片、本机读写、自定义快捷键、双设备文件夹合并、删除清空传播、复制、损坏文件保护和浮层布局通过")
        success = true
    } catch {
        print("✗ 剪贴板自检失败[\(stage)]：\(error.localizedDescription)")
    }
    defaults.removePersistentDomain(forName: suite)
    board.releaseGlobally()
    try? FileManager.default.removeItem(at: root)
    exit(success ? 0 : 1)
}
