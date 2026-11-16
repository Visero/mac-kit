//
//  OCRWindow.swift
//  MacKit
//
//  图片取字结果窗口：显示识别文字，可选显示译文。
//

import AppKit

final class OCRResultWindowController: NSWindowController {
    static let shared = OCRResultWindowController()

    private var sourceView: NSTextView!
    private var translatedView: NSTextView!
    private var translatedTitle: NSTextField!
    private var statusLabel: NSTextField!
    private var sourceScroll: NSScrollView!
    private var translatedScroll: NSScrollView!
    private var copyTranslatedButton: NSButton!
    private var wantsTranslation = false
    /// macOS 15+ 才有的翻译服务；用 AnyObject 存，避免类本身被 availability 限制
    private var translationServiceBox: AnyObject?

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "提取文字"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 260)
        self.init(window: window)
        buildContent(in: window)
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        statusLabel = NSTextField(labelWithString: "正在识别…")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        sourceScroll = makeTextView(&sourceView)
        translatedScroll = makeTextView(&translatedView)
        translatedScroll.isHidden = true

        translatedTitle = NSTextField(labelWithString: "译文")
        translatedTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        translatedTitle.textColor = .secondaryLabelColor
        translatedTitle.isHidden = true

        let copySource = NSButton(title: "复制原文", target: self, action: #selector(copySource))
        copyTranslatedButton = NSButton(title: "复制译文", target: self, action: #selector(copyTranslated))
        copyTranslatedButton.isHidden = true
        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        for button in [copySource, copyTranslatedButton!, close] {
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(button)
        }

        for view in [statusLabel, translatedTitle] {
            view!.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view!)
        }
        for scroll in [sourceScroll, translatedScroll] {
            scroll!.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(scroll!)
        }

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),

            sourceScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            sourceScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sourceScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),

            translatedTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            translatedTitle.topAnchor.constraint(equalTo: sourceScroll.bottomAnchor, constant: 10),

            translatedScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            translatedScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            translatedScroll.topAnchor.constraint(equalTo: translatedTitle.bottomAnchor, constant: 6),
            translatedScroll.bottomAnchor.constraint(equalTo: copySource.topAnchor, constant: -10),
            translatedScroll.heightAnchor.constraint(equalTo: sourceScroll.heightAnchor),

            copySource.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            copySource.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            copyTranslatedButton.leadingAnchor.constraint(equalTo: copySource.trailingAnchor, constant: 8),
            copyTranslatedButton.centerYAnchor.constraint(equalTo: copySource.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            close.centerYAnchor.constraint(equalTo: copySource.centerYAnchor)
        ])

        if !wantsTranslation {
            translatedScroll.isHidden = true
            translatedTitle.isHidden = true
        }

        if #available(macOS 15.0, *) {
            let service = AppleTranslationService()
            service.attach(to: content)
            translationServiceBox = service
        }
    }

    private func makeTextView(_ storage: inout NSTextView!) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        storage = text
        return scroll
    }

    func show(image: NSImage, translate: Bool) {
        wantsTranslation = translate
        translatedTitle.isHidden = !translate
        translatedScroll.isHidden = !translate
        copyTranslatedButton.isHidden = !translate
        sourceView.string = ""
        translatedView.string = ""
        statusLabel.stringValue = "正在识别…"
        statusLabel.textColor = .secondaryLabelColor

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task {
            let text = await ImageOCR.recognize(image)
            await MainActor.run {
                guard let text, !text.isEmpty else {
                    statusLabel.stringValue = "没有识别到文字"
                    statusLabel.textColor = .systemOrange
                    return
                }
                sourceView.string = text
                statusLabel.stringValue = "识别到 \(text.count) 个字符"
                if translate {
                    translateText(text)
                }
            }
        }
    }

    private func translateText(_ text: String) {
        guard #available(macOS 15.0, *) else {
            statusLabel.stringValue = "识别完成；系统版本不支持 Apple 翻译"
            statusLabel.textColor = .systemOrange
            return
        }
        statusLabel.stringValue = "识别完成，正在翻译…"
        let service = translationServiceBox as? AppleTranslationService
        service?.translate(text) { [weak self] translated in
            guard let self else { return }
            if let translated, !translated.isEmpty {
                self.translatedView.string = translated
                self.statusLabel.stringValue = "识别并翻译完成"
                self.statusLabel.textColor = .secondaryLabelColor
            } else {
                self.statusLabel.stringValue = "翻译未完成：请在弹窗里下载语言包后重试"
                self.statusLabel.textColor = .systemOrange
            }
        }
    }

    @objc private func copySource() {
        copy(sourceView.string)
    }

    @objc private func copyTranslated() {
        copy(translatedView.string)
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "已复制到剪贴板"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
