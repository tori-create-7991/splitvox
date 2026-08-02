import AVFAudio
import CoreMedia
import Foundation
import Speech

/// Transcribes one side of the call while it is still being recorded.
///
/// `Transcriber` reads a finished file; this one is fed buffers as they are
/// captured. `SpeechAnalyzer` is built for streaming, so this is the shape the
/// API expects — the file-based path is the simplification, not this.
///
/// Only finalised results are surfaced. Volatile results exist but produce text
/// that rewrites itself as recognition settles, which is noise in a meeting
/// transcript nobody is watching live.
final class LiveTranscriber {

    private let requestedLocale: Locale

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<Void, Never>?
    private var converter: AVAudioConverter?

    /// Format the analyzer asked for. Exposed so `--probe-live` can show
    /// whether a conversion is happening at all.
    private(set) var analyzerFormat: AVAudioFormat?

    /// Kept only to size converted buffers; the analyzer owns the timeline.
    private var sourceSampleRate: Double = 0

    /// Called on every newly finalised segment. Never on the audio thread.
    var onSegment: ((TranscriptSegment) -> Void)?

    /// Counters for `--probe-live`, so a silent failure can be located instead
    /// of guessed at. Written from the audio callback and the results task.
    struct Stats {
        var appended = 0
        var yielded = 0
        var conversionFailures = 0
        var resultsReceived = 0
        var finalResults = 0
        var streamError: String?
    }

    private let statsLock = NSLock()
    private var _stats = Stats()

    var stats: Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _stats
    }

    private func mutateStats(_ body: (inout Stats) -> Void) {
        statsLock.lock()
        defer { statsLock.unlock() }
        body(&_stats)
    }

    init(localeIdentifier: String = Config.transcriptionLocaleIdentifier) {
        self.requestedLocale = Locale(identifier: localeIdentifier)
    }

    func start(sourceFormat: AVAudioFormat) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriberError.localeUnsupported(requestedLocale.identifier)
        }

        let module = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )

        // The analyzer picks the format it wants; the tap delivers whatever the
        // aggregate device negotiated. A converter bridges the two.
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else {
            throw TranscriberError.modelUnavailable(locale.identifier)
        }
        analyzerFormat = targetFormat
        sourceSampleRate = sourceFormat.sampleRate

        if sourceFormat != targetFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        // Built without the sequence, then started with it below. An
        // AsyncStream can only be consumed once, so it must not be handed to
        // both the initialiser and `start`.
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer

        // Subscribe before any audio is appended, otherwise early results are
        // dropped on the floor.
        collector = Task { [weak self] in
            do {
                for try await result in module.results {
                    self?.mutateStats { $0.resultsReceived += 1 }
                    guard result.isFinal else { continue }
                    self?.mutateStats { $0.finalResults += 1 }

                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    self?.onSegment?(
                        TranscriptSegment(
                            start: CMTimeGetSeconds(result.range.start),
                            end: CMTimeGetSeconds(result.range.end),
                            text: text
                        )
                    )
                }
            } catch {
                // The recording continues regardless: the audio file is the
                // durable artifact and can be transcribed again afterwards.
                self?.mutateStats { $0.streamError = error.localizedDescription }
            }
        }

        // `init(inputSequence:)` alone did not appear to drive analysis, so the
        // analyzer is started explicitly against the same stream.
        try await analyzer.start(inputSequence: stream)
    }

    /// Feed captured audio. Safe to call from the audio callback queue, which
    /// is serial, so the converter is never used concurrently.
    /// Feed captured audio. Safe to call from the audio callback queue, which
    /// is serial, so the converter is never used concurrently.
    ///
    /// No `bufferStartTime` is supplied. Deriving one from the source frame
    /// count while handing over *converted* buffers made the analyzer reject
    /// every input with "Audio input timestamp overlaps or precedes prior audio
    /// input": it advances its own clock by the converted buffer's length, and
    /// the two accumulations drift apart by rounding. Letting the analyzer keep
    /// time is both simpler and correct — the stream starts when recording
    /// starts, so its timeline already is the recording's timeline.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
        mutateStats { $0.appended += 1 }

        guard let converter, let analyzerFormat else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            mutateStats { $0.yielded += 1 }
            return
        }

        let ratio = analyzerFormat.sampleRate / (sourceSampleRate == 0 ? 1 : sourceSampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: capacity
        ) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, converted.frameLength > 0 else {
            mutateStats { $0.conversionFailures += 1 }
            return
        }
        continuation.yield(AnalyzerInput(buffer: converted))
        mutateStats { $0.yielded += 1 }
    }

    /// Stop accepting audio and wait for the analyzer to finish the tail.
    func finish() async {
        continuation?.finish()
        continuation = nil

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await collector?.value

        analyzer = nil
        collector = nil
        converter = nil
    }
}
