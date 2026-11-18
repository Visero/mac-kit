//
//  ImageOCR.swift
//  MacKit
//
//  剪贴板图片取字（Vision 本地识别）与 Apple 翻译。
//

import AppKit
import SwiftUI
import Translation
import Vision
import NaturalLanguage

enum ImageOCR {
    /// 用 NaturalLanguage 猜一下主要语言，翻译时显式传源语言更稳
    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// 本地识别图片文字，日语 / 英语 / 简体中文优先
    static func recognize(
        _ image: NSImage,
        languages: [String] = ["ja-JP", "en-US", "zh-Hans", "zh-Hant"]
    ) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Vision 对象仅在执行队列创建和使用，不跨并发边界传递。
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = languages
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                    continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Apple 翻译

/// `.translationTask` 需要一个 SwiftUI 视图承载，这里用一个隐藏窗口托管。
@available(macOS 15.0, *)
final class AppleTranslationService: ObservableObject {
    static let shared = AppleTranslationService()

    @Published fileprivate var configuration: TranslationSession.Configuration?

    private var hostView: NSView?
    private var pending: [(String, String, (String?) -> Void)] = []
    private var busy = false

    var isAvailable: Bool { true }

    /// 把文字翻译成指定语言；失败时回调 nil
    func translate(_ text: String, to language: String = "zh-Hans", completion: @escaping (String?) -> Void) {
        // 隐藏窗口必须在主线程创建
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.translate(text, to: language, completion: completion)
            }
            return
        }
        pending.append((text, language, completion))
        let source = ImageOCR.detectLanguage(text)
        configuration = TranslationSession.Configuration(
            source: source.map { Locale.Language(identifier: $0) },
            target: Locale.Language(identifier: language)
        )
    }

    fileprivate func drain(session: TranslationSession) async {
        while !pending.isEmpty {
            let (text, _, completion) = pending.removeFirst()
            do {
                // 源语言由调用方显式给出；语言包缺失时这里会弹出系统下载面板
                try await session.prepareTranslation()
                let response = try await session.translate(text)
                await MainActor.run { completion(response.targetText) }
            } catch {
                NSLog("MacKit OCR 翻译失败: \(error.localizedDescription)")
                await MainActor.run { completion(nil) }
            }
        }
    }

    /// 把承载 `.translationTask` 的视图挂到调用方的窗口上：
    /// 语言包下载提示需要依附在可见窗口，隐藏窗口会直接失败。
    func attach(to container: NSView) {
        guard hostView == nil else { return }
        let host = NSHostingView(rootView: TranslationHost(service: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 1),
            host.heightAnchor.constraint(equalToConstant: 1),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        hostView = host
    }
}

@available(macOS 15.0, *)
struct TranslationHost: View {
    @ObservedObject var service: AppleTranslationService

    var body: some View {
        Color.clear
            .translationTask(service.configuration) { session in
                await service.drain(session: session)
            }
    }
}
