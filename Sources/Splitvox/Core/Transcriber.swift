import AVFAudio
import CoreMedia
import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case localeUnsupported(String)
    case modelUnavailable(String)
    case fileUnreadable(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let identifier):
            return "この端末の音声認識は \(identifier) に対応していません"
        case .modelUnavailable(let identifier):
            return "\(identifier) の音声認識モデルを利用できません。"
                + " システム設定の言語と地域からモデルを追加してください"
        case .fileUnreadable(let url, let underlying):
            return "録音ファイルを読み込めませんでした: \(url.lastPathComponent)"
                + " (\(underlying.localizedDescription))"
        }
    }
}

/// On-device transcription via SpeechAnalyzer.
///
/// Each file is transcribed independently. That is the point: `me.wav` and
/// `them.wav` never share a recogniser, so no cross-talk can leak between the
/// two speakers at this stage either.
final class Transcriber {

    private let requestedLocale: Locale

    init(localeIdentifier: String = PreferenceStore().transcriptionLocaleIdentifier) {
        self.requestedLocale = Locale(identifier: localeIdentifier)
    }

    /// The locale this device will actually recognise, which may be a regional
    /// variant of the requested one.
    func resolvedLocale() async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriberError.localeUnsupported(requestedLocale.identifier)
        }
        return supported
    }

    func isModelInstalled() async -> Bool {
        guard let locale = try? await resolvedLocale() else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
    }

    /// Download the recognition model if it is not present yet.
    ///
    /// Reported rather than silently skipped: without the model, transcription
    /// returns nothing, and an empty transcript looks like a recording failure.
    func ensureModelInstalled(onProgress: ((Double) -> Void)? = nil) async throws {
        let locale = try await resolvedLocale()
        let module = SpeechTranscriber(locale: locale, preset: Self.preset)

        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return
        case .unsupported:
            throw TranscriberError.modelUnavailable(locale.identifier)
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                throw TranscriberError.modelUnavailable(locale.identifier)
            }
            if let onProgress {
                onProgress(request.progress.fractionCompleted)
            }
            try await request.downloadAndInstall()
        @unknown default:
            throw TranscriberError.modelUnavailable(locale.identifier)
        }
    }

    func transcribe(fileURL: URL) async throws -> [TranscriptSegment] {
        let locale = try await resolvedLocale()
        let module = SpeechTranscriber(locale: locale, preset: Self.preset)
        let analyzer = SpeechAnalyzer(modules: [module])

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriberError.fileUnreadable(fileURL, underlying: error)
        }

        // Results arrive on their own stream, so collection has to be running
        // before the analysis is driven or early results are dropped.
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in module.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(
                    TranscriptSegment(
                        start: CMTimeGetSeconds(result.range.start),
                        end: CMTimeGetSeconds(result.range.end),
                        text: text
                    )
                )
            }
            return segments
        }

        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await collector.value
    }

    /// Carries `audioTimeRange`, which is what makes the two transcripts
    /// mergeable on a shared timeline.
    private static let preset = SpeechTranscriber.Preset.timeIndexedTranscriptionWithAlternatives
}
