import AppKit
import Combine
import CoreML
import NaturalLanguage
import SwiftUI
import Translation
import Vision

struct RecognizedText {
    let text: String
    let confidence: VNConfidence
}

enum TextReader {
    static func read(_ image: CGImage, quality: VNRequestTextRecognitionLevel) throws -> RecognizedText {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = quality
        request.usesLanguageCorrection = true
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        if quality == .accurate {
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        } else {
            request.recognitionLanguages = ["en-US"]
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        let text = lines.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return RecognizedText(text: text, confidence: lines.map(\.confidence).min() ?? 0)
    }
}

struct ImageText {
    let preview: Task<RecognizedText, Never>
    let complete: Task<RecognizedText, Error>

    func resolvedText(fallingBackTo first: String) async throws -> String {
        do {
            let accurate = try await complete.value.text
            return accurate.isEmpty ? first : accurate
        } catch where !first.isEmpty {
            return first
        }
    }
}

extension ImageText {
    init(_ image: CGImage) {
        let quick = Task.detached(priority: .userInitiated) {
            (try? TextReader.read(image, quality: .fast)) ?? RecognizedText(text: "", confidence: 0)
        }
        preview = quick
        complete = Task.detached(priority: .userInitiated) {
            _ = await quick.value
            try Task.checkCancellation()
            return try TextReader.read(image, quality: .accurate)
        }
    }
}

@MainActor
private func isEnglishWord(_ text: String) -> Bool {
    let word = text.trimmingCharacters(in: .punctuationCharacters)
    guard word.range(of: #"^[A-Za-z]+(?:[-'’][A-Za-z]+)*$"#, options: .regularExpression) != nil else { return false }
    return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en_US",
        wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
}

@MainActor
final class TextResultModel: ObservableObject {
    @Published var output = ""
    @Published var source = ""
    @Published var status = "正在识别截图中的文字…"
    @Published var refining = false
    @Published var copied = false
    @Published var translation: TranslationSession.Configuration?

    func recognize(_ reading: ImageText, translate: Bool) async {
        let first = await reading.preview.value
        guard !Task.isCancelled else { return }
        if !first.text.isEmpty {
            source = first.text
            if !translate {
                output = first.text
                refining = true
            } else if first.confidence >= 0.85 && isEnglishWord(first.text) {
                await translateText(first.text)
                return
            } else {
                status = "正在校对识别结果…"
            }
        }

        let text: String
        do {
            text = try await reading.resolvedText(fallingBackTo: first.text)
        } catch {
            guard !Task.isCancelled else { return }
            refining = false
            status = "无法识别文字。\n" + error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }
        refining = false
        guard !text.isEmpty else { status = "这张截图中没有识别到文字。"; return }
        if translate {
            await translateText(text)
        } else {
            source = text
            copied = false
            output = text
        }
    }

    func translateText(_ text: String) async {
        guard !Task.isCancelled else { return }
        source = text
        status = "正在翻译为简体中文…"
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        var language = recognizer.dominantLanguage
        // One word gives the language classifier little context. Prefer a known
        // English spelling only when the detector itself is uncertain.
        if (recognizer.languageHypotheses(withMaximum: 1).values.first ?? 0) < 0.6 && isEnglishWord(text) {
            language = .english
        }
        if language == .simplifiedChinese || language == .traditionalChinese {
            output = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
            return
        }
        let target = Locale.Language(identifier: "zh-Hans")
        let from = language.map { Locale.Language(identifier: $0.rawValue) }
        if let from {
            let availability = await LanguageAvailability().status(from: from, to: target)
            guard !Task.isCancelled else { return }
            switch availability {
            case .unsupported:
                status = "系统翻译暂不支持这段文字的源语言。"; return
            case .supported:
                status = "首次翻译需要语言包，请按系统提示下载。"
            default:
                break
            }
        }
        translation = .init(source: from, target: target)
    }

}

struct TextResultView: View {
    @ObservedObject var model: TextResultModel
    let translating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if translating && !model.source.isEmpty {
                Text("原文　" + model.source).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            if model.output.isEmpty {
                Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    Text(model.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    if model.refining { Text("正在校对识别结果…").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(model.copied ? "已复制" : "复制文字") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        model.copied = pasteboard.setString(model.output, forType: .string)
                    }.keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
        }
        .padding(18)
        .translationTask(model.translation) { session in
            do {
                let response = try await session.translate(model.source)
                if !Task.isCancelled { model.output = response.targetText }
            } catch {
                if !Task.isCancelled { model.status = "未能翻译为简体中文。\n" + error.localizedDescription }
            }
        }
    }
}
