import AVFoundation
import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

/// `Splitvox --probe-tap` — create a tap against the configured meeting
/// applications, report what it resolved, and destroy it.
///
/// Exists because every interesting failure in the capture path is invisible
/// from unit tests: whether a bundle ID matches a live process, what format the
/// tap negotiates, and whether taps leak when a session ends.
enum ProbeCommand {

    static func run(bundleIDs: [String]) {
        print("configured bundle IDs:")
        for id in bundleIDs { print("  \(id)") }

        let matched = AudioProcessLookup.processObjectIDs(forBundleIDs: bundleIDs)
        print("\nmatching process objects: \(matched.count)")
        for object in matched {
            let bundle = AudioProcessLookup.bundleID(of: object) ?? "(unknown)"
            let active = AudioProcessLookup.isProducingOutput(object) ? "  <- producing output" : ""
            print("  [\(object)] \(bundle)\(active)")
        }

        let producing = AudioProcessLookup.bundleIDsProducingOutput()
        print("\nbundle IDs producing output right now: \(producing.isEmpty ? "(none)" : "")")
        for id in Set(producing).sorted() {
            let covered = bundleIDs.contains(id) ? "captured" : "NOT captured"
            print("  \(id)  — \(covered)")
        }

        let tapsBefore = ProcessTap.systemTapIDs().count

        do {
            let tap = try ProcessTap(bundleIDs: bundleIDs)
            print("\ntap created")
            print("  objectID: \(tap.tapID)")
            print("  uid:      \(tap.uid)")

            if let format = tap.streamDescription {
                print("  format:   \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, "
                      + "\(format.mBitsPerChannel) bit")
            } else {
                print("  format:   (unavailable)")
            }

            print("  system taps: \(tapsBefore) -> \(ProcessTap.systemTapIDs().count)")

            let destroyStatus = tap.invalidate()
            print("  destroy status: \(destroyStatus)"
                  + (destroyStatus == noErr ? " (noErr)" : " (FAILED)"))
            print("  immediately after destroy: \(ProcessTap.systemTapIDs().count)")

            // The tap list is maintained by coreaudiod, so a destroy may not be
            // reflected in the very next property read from this process.
            Thread.sleep(forTimeInterval: 0.3)
            let tapsAfter = ProcessTap.systemTapIDs().count
            print("  after 300ms:               \(tapsAfter)")

            print(tapsAfter == tapsBefore
                  ? "\nOK — no tap leaked."
                  : "\nWARNING — tap count did not return to \(tapsBefore).")
        } catch {
            print("\ntap creation FAILED: \(error.localizedDescription)")
        }
    }

    /// `Splitvox --probe-record <seconds>` — record for real, then report
    /// per-second levels for each file.
    ///
    /// This is how Success Criterion 2 is checked: during a window where only
    /// one side speaks, that side's file should be loud and the other quiet.
    /// Must be run from the built `.app`, because microphone access requires
    /// `NSMicrophoneUsageDescription` from a bundle Info.plist.
    static func probeRecord(
        bundleIDs: [String],
        preferredInputUID: String?,
        seconds: TimeInterval,
        outputDirectory: URL
    ) {
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let recorder = try AggregateRecorder(
                bundleIDs: bundleIDs,
                preferredInputUID: preferredInputUID
            )
            let microphoneURL = RecordingStore.microphoneFileURL(in: outputDirectory)
            let systemAudioURL = RecordingStore.systemAudioFileURL(in: outputDirectory)

            print("input device: \(recorder.inputDeviceName)")
            print("layout: mic ch \(recorder.layout.microphoneChannels), "
                  + "tap ch \(recorder.layout.systemAudioChannels)")
            print("microphone permission: \(describeMicrophonePermission())")
            print("\nrecording \(Int(seconds))s — speak, and play audio in the meeting app")

            try recorder.start(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)

            for remaining in stride(from: Int(seconds), through: 1, by: -1) {
                print("  \(remaining)…", terminator: "\n")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 1)
            }

            recorder.stop()
            print("\nbuffers delivered by the device: \(recorder.observedBufferLayout)")
            if recorder.writeFailures > 0 {
                print("WRITE FAILURES: \(recorder.writeFailures)"
                      + (recorder.firstWriteError.map { " — \($0)" } ?? ""))
            }
            print("stopped. wrote:")
            print("  \(microphoneURL.path)")
            print("  \(systemAudioURL.path)")

            report("me.wav   (microphone)", url: microphoneURL)
            report("them.wav (meeting app)", url: systemAudioURL)
        } catch {
            print("\nFAILED: \(error.localizedDescription)")
        }
    }

    /// Core Audio reports the aggregate device as N channels while
    /// `AVAudioEngine` reported 1. This narrows down which layer drops them:
    /// a stale read after assignment, or the AUHAL client-side format.
    private static func diagnoseEngineFormats(aggregateDeviceID: AudioObjectID) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        print("\nAVAudioEngine input formats")
        print("  before assignment: \(describe(inputNode.inputFormat(forBus: 0)))")

        guard let audioUnit = inputNode.audioUnit else {
            print("  audioUnit unavailable")
            return
        }

        var deviceID = aggregateDeviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        print("  assignment status: \(status)")
        print("  immediately after: \(describe(inputNode.inputFormat(forBus: 0)))")

        Thread.sleep(forTimeInterval: 0.3)
        print("  after 300ms:       \(describe(inputNode.inputFormat(forBus: 0)))")

        // AUHAL bus 1 is the input bus. Its input scope faces the hardware and
        // its output scope faces the client; a mismatch between them is what
        // silently reduces the channel count.
        printUnitFormat(audioUnit, scope: kAudioUnitScope_Input, bus: 1, label: "  AUHAL bus1 input  (hardware)")
        printUnitFormat(audioUnit, scope: kAudioUnitScope_Output, bus: 1, label: "  AUHAL bus1 output (client)  ")
    }

    private static func printUnitFormat(
        _ unit: AudioUnit,
        scope: AudioUnitScope,
        bus: AudioUnitElement,
        label: String
    ) {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, bus, &asbd, &size)
        if status == noErr {
            print("\(label): \(asbd.mChannelsPerFrame) ch, \(asbd.mSampleRate) Hz")
        } else {
            print("\(label): unavailable (OSStatus \(status))")
        }
    }

    /// `AudioDeviceStart` returns `noErr` even when microphone consent is
    /// missing — the callbacks simply never arrive. Reading the status makes
    /// that failure visible instead of looking like a broken device.
    static func describeMicrophonePermission() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined (未確認 — 許可ダイアログが必要)"
        case .denied: return "DENIED (システム設定 → プライバシーとセキュリティ → マイク)"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(format.channelCount) ch, \(format.sampleRate) Hz"
            + (format.isInterleaved ? ", interleaved" : ", deinterleaved")
    }

    /// `Splitvox --probe-detect [seconds]` — watch the meeting-detection signal
    /// without recording anything.
    ///
    /// Lets the trigger be tuned against real usage — a real meeting, and a
    /// video that must *not* fire it — before trusting it to start recordings
    /// unattended.
    static func probeDetect(
        bundleIDs: [String],
        seconds: TimeInterval,
        conditions: AutoRecordConditions
    ) {
        print("watching for \(Int(seconds))s — ヘッドセットの抜き差しで試してください")
        print("現在の既定入力: \(AudioDeviceLookup.defaultInputName() ?? "(不明)")")
        print("有効な条件（すべて満たす必要あり）:")
        for c in AutoRecordConditions.all where conditions.contains(c) {
            print("  ・\(c.label)")
        }
        if conditions.isEmpty { print("  （なし — 自動記録は無効）") }
        print("")

        var trigger = MeetingTrigger()
        var lastState: Bool?
        let started = ProcessInfo.processInfo.systemUptime

        while ProcessInfo.processInfo.systemUptime - started < seconds {
            let now = ProcessInfo.processInfo.systemUptime
            let sample = MeetingDetector.sample(meetingBundleIDs: bundleIDs)
            let action = trigger.observe(meetingDetected: sample.shouldRecord(matching: conditions), at: now)

            if sample.shouldRecord(matching: conditions) != lastState || action != .none {
                lastState = sample.shouldRecord(matching: conditions)
                let elapsed = Int(now - started)
                let verdict = sample.shouldRecord(matching: conditions) ? "RECORD " : "-      "
                print("[\(elapsed)s] \(verdict)  ヘッドセット: \(sample.headsetActive ? "○" : "×")"
                      + "  |  実機: \(sample.physicalHeadsetActive ? "○" : "×")"
                      + "  |  マイク: \(sample.microphoneInUse ? "○" : "×")"
                      + "  |  再生: \(sample.playing.joined(separator: ", "))")
                if action != .none {
                    print("        -> \(action == .start ? "録音を開始する条件を満たしました" : "停止条件を満たしました")")
                }
            }

            Thread.sleep(forTimeInterval: 1)
        }
        print("\n終了。")
    }

    /// `Splitvox --list-apps` — every process Core Audio knows about, plus the
    /// applications installed on this machine and their bundle IDs.
    ///
    /// Answers the question the settings screen keeps raising: "what do I put
    /// in the bundle ID list for app X". Helper-process IDs are undocumented
    /// and differ per app, so they have to be read off the running system.
    static func listApps(configured: [String]) {
        let configuredSet = Set(configured)

        print("=== Core Audio に登録されているプロセス ===")
        let objects = AudioProcessLookup.allProcessObjectIDs()
        var rows: [(bundle: String, output: Bool)] = []
        for object in objects {
            guard let bundle = AudioProcessLookup.bundleID(of: object), !bundle.isEmpty else { continue }
            rows.append((bundle, AudioProcessLookup.isProducingOutput(object)))
        }

        for row in rows.sorted(by: { $0.bundle < $1.bundle }) {
            let mark = configuredSet.contains(row.bundle) ? "[設定済]" : "        "
            let playing = row.output ? "  <- 再生中" : ""
            print("  \(mark) \(row.bundle)\(playing)")
        }

        print("\n=== インストール済みアプリ ===")
        for app in InstalledAppLookup.scan() {
            let ids = app.allBundleIDs
            let covered = ids.allSatisfy { configuredSet.contains($0) }
            print("  \(covered ? "[設定済]" : "        ") \(app.name)")
            for id in ids {
                print("             \(id)")
            }
        }

        print("\n設定に貼る場合は上記のバンドルIDを1行に1つ書いてください。")
    }

    /// Collects live segments from both transcribers, which deliver on
    /// different tasks, so the accumulator needs guarding.
    private final class LiveCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var accumulator = TranscriptAccumulator()

        func add(_ segment: TranscriptSegment, from speaker: Speaker) {
            lock.lock()
            defer { lock.unlock() }
            accumulator.add(segment, from: speaker)
        }

        var snapshot: (markdown: String, count: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (accumulator.markdown(), accumulator.me.count + accumulator.them.count)
        }
    }

    /// `Splitvox --probe-live [seconds]` — transcribe while recording, printing
    /// the transcript as it grows.
    ///
    /// Exercises the live path end to end, which the file-based probes do not
    /// touch at all.
    static func probeLive(
        bundleIDs: [String],
        preferredInputUID: String?,
        seconds: TimeInterval,
        outputDirectory: URL,
        pollProcessesWhileRecording: Bool = false
    ) async {
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let recorder = try AggregateRecorder(
                bundleIDs: bundleIDs,
                preferredInputUID: preferredInputUID
            )
            guard let microphoneFormat = recorder.microphoneFormat,
                  let systemAudioFormat = recorder.systemAudioFormat else {
                print("could not derive capture formats")
                return
            }

            print("input device: \(recorder.inputDeviceName)")
            print("mic format:   \(microphoneFormat.channelCount) ch @ \(microphoneFormat.sampleRate) Hz")
            print("tap format:   \(systemAudioFormat.channelCount) ch @ \(systemAudioFormat.sampleRate) Hz")

            let collector = LiveCollector()
            let microphone = LiveTranscriber()
            let systemAudio = LiveTranscriber()

            microphone.onSegment = { collector.add($0, from: .me) }
            systemAudio.onSegment = { collector.add($0, from: .them) }

            print("\nstarting live transcribers…")
            try await microphone.start(sourceFormat: microphoneFormat)
            try await systemAudio.start(sourceFormat: systemAudioFormat)

            if let format = microphone.analyzerFormat {
                print("analyzer wants: \(format.channelCount) ch @ \(format.sampleRate) Hz"
                      + (format == microphoneFormat ? " (no conversion)" : " (converting)"))
            }

            recorder.onMicrophoneBuffer = { microphone.append($0) }
            recorder.onSystemAudioBuffer = { systemAudio.append($0) }

            try recorder.start(
                microphoneURL: RecordingStore.microphoneFileURL(in: outputDirectory),
                systemAudioURL: RecordingStore.systemAudioFileURL(in: outputDirectory)
            )

            if pollProcessesWhileRecording {
                print("(録音中も Core Audio のプロセス列挙を続けます — アプリ本体と同じ条件)")
            }
            print("recording \(Int(seconds))s — speak, and play audio in the meeting app\n")

            var lastCount = -1
            for remaining in stride(from: Int(seconds), through: 1, by: -1) {
                let snapshot = collector.snapshot
                if snapshot.count != lastCount {
                    lastCount = snapshot.count
                    print("  [\(remaining)s left] \(snapshot.count) segments so far")
                }

                // Reproduces what the menu bar app does throughout a recording:
                // its detection and logging timers keep enumerating audio
                // processes. If that is what silences the tap, it shows up here.
                if pollProcessesWhileRecording {
                    _ = MeetingDetector.sample(meetingBundleIDs: bundleIDs)
                    _ = AudioProcessLookup.bundleIDsProducingOutput()
                }

                // Task.sleep, not Thread.sleep: blocking the cooperative pool
                // here would stall the transcribers running on it.
                try? await Task.sleep(for: .seconds(1))
            }

            recorder.stop()
            await microphone.finish()
            await systemAudio.finish()

            let final = collector.snapshot
            print("\nfinal: \(final.count) segments")

            // Locates a silent failure: no appends means the audio never
            // reached the transcriber, no yields means conversion dropped it,
            // and results without finals means recognition ran but never
            // committed anything.
            for (label, transcriber) in [("mic", microphone), ("tap", systemAudio)] {
                let s = transcriber.stats
                print("  \(label): appended=\(s.appended) yielded=\(s.yielded) "
                      + "convFail=\(s.conversionFailures) "
                      + "results=\(s.resultsReceived) final=\(s.finalResults)"
                      + (s.streamError.map { " error=\($0)" } ?? ""))
            }

            print("\n--- transcript.md ---")
            print(final.markdown.isEmpty ? "(no speech recognised)" : final.markdown)
        } catch {
            print("\nFAILED: \(error.localizedDescription)")
        }
    }

    /// `Splitvox --probe-full [seconds]` — record, then transcribe, in one run.
    ///
    /// The end-to-end path a real meeting takes, driven from the command line
    /// so it can be exercised before the menu bar UI exists.
    static func probeFull(
        bundleIDs: [String],
        preferredInputUID: String?,
        seconds: TimeInterval,
        outputDirectory: URL
    ) async {
        probeRecord(
            bundleIDs: bundleIDs,
            preferredInputUID: preferredInputUID,
            seconds: seconds,
            outputDirectory: outputDirectory
        )

        guard FileManager.default.fileExists(
            atPath: RecordingStore.microphoneFileURL(in: outputDirectory).path
        ) else { return }

        print("\n================ transcription ================")
        await probeTranscribe(directory: outputDirectory)
    }

    /// `Splitvox --probe-transcribe [directory]` — transcribe an existing
    /// `me.wav` / `them.wav` pair and print the merged Markdown.
    ///
    /// Runs the whole downstream half of the pipeline against a recording that
    /// already exists, so transcription can be checked without recording again.
    static func probeTranscribe(directory: URL) async {
        let transcriber = Transcriber()

        do {
            let locale = try await transcriber.resolvedLocale()
            let installed = await transcriber.isModelInstalled()
            print("locale: \(locale.identifier)")
            print("model installed: \(installed)")

            if !installed {
                print("downloading model…")
                try await transcriber.ensureModelInstalled { fraction in
                    print(String(format: "  %.0f%%", fraction * 100))
                }
                print("model ready")
            }
        } catch {
            print("model check FAILED: \(error.localizedDescription)")
            return
        }

        let microphoneURL = RecordingStore.microphoneFileURL(in: directory)
        let systemAudioURL = RecordingStore.systemAudioFileURL(in: directory)

        for url in [microphoneURL, systemAudioURL] where !FileManager.default.fileExists(atPath: url.path) {
            print("missing: \(url.path)")
            return
        }

        // Levels first: a file with no speech in it and a file the recogniser
        // failed on both produce zero segments, and only the level tells them
        // apart.
        for url in [microphoneURL, systemAudioURL] {
            if let analysis = try? AudioAnalysis.analyse(url) {
                // Levels only, deliberately without a "was anyone speaking"
                // verdict. Both a steady room tone and someone talking without
                // pause produce a small average-to-peak gap, because the peak
                // here is the loudest one-second window, so no threshold on
                // these numbers separates the two. They still answer the
                // question that matters — whether the file is silent.
                let average = AudioAnalysis.decibels(analysis.overallRMS)
                let peak = AudioAnalysis.decibels(analysis.peakRMS)
                print(String(format: "%@: 平均 %.1f / ピーク %.1f dBFS",
                             url.lastPathComponent, average, peak))
            }
        }

        do {
            print("\ntranscribing \(microphoneURL.lastPathComponent)…")
            let me = try await transcriber.transcribe(fileURL: microphoneURL)
            print("  \(me.count) segments")

            print("transcribing \(systemAudioURL.lastPathComponent)…")
            let them = try await transcriber.transcribe(fileURL: systemAudioURL)
            print("  \(them.count) segments")

            let merged = TranscriptMerger.mergeCoalescing(me: me, them: them)
            print("\nsegments: \(me.count + them.count) -> \(merged.count) after coalescing")

            let markdown = TranscriptMerger.markdown(for: merged)
            print("\n--- transcript.md ---")
            print(markdown.isEmpty ? "(no speech recognised)" : markdown)
        } catch {
            print("transcription FAILED: \(error.localizedDescription)")
        }
    }

    private static func report(_ label: String, url: URL) {
        do {
            let analysis = try AudioAnalysis.analyse(url)
            print("\n\(label)")
            print(String(format: "  duration: %.2fs  %d ch  %.0f Hz",
                         analysis.duration, analysis.channelCount, analysis.sampleRate))
            print(String(format: "  overall RMS: %.6f (%.1f dBFS)",
                         analysis.overallRMS, AudioAnalysis.decibels(analysis.overallRMS)))
            let perSecond = analysis.perSecondRMS
                .map { String(format: "%.0f", AudioAnalysis.decibels($0)) }
                .joined(separator: " ")
            print("  per-second dBFS: \(perSecond)")
        } catch {
            print("\n\(label): could not analyse — \(error.localizedDescription)")
        }
    }

    /// `Splitvox --probe-aggregate` — build the real capture device and report
    /// its channel layout, which decides how the recorder splits the incoming
    /// buffer into the two files.
    static func probeAggregate(bundleIDs: [String], preferredInputUID: String?) {
        guard let input = AudioDeviceLookup.resolveInputDevice(preferredUID: preferredInputUID) else {
            print("no input device available")
            return
        }

        print("input devices:")
        for device in AudioDeviceLookup.availableInputDevices() {
            let marker = device.uid == input.uid ? " <- selected" : ""
            print("  \(device.name)  [\(device.inputChannelCount) ch]  \(device.uid)\(marker)")
        }

        do {
            let tap = try ProcessTap(bundleIDs: bundleIDs)
            defer { tap.invalidate() }

            let tapChannels = tap.streamDescription.map { Int($0.mChannelsPerFrame) } ?? 0
            print("\ntap: \(tapChannels) ch, uid \(tap.uid)")

            let aggregate = try AggregateDevice(tapUID: tap.uid, inputDeviceUID: input.uid)
            defer { aggregate.invalidate() }

            print("\naggregate device created")
            print("  objectID:     \(aggregate.deviceID)")
            print("  sample rate:  \(aggregate.nominalSampleRate) Hz")
            print("  total input:  \(aggregate.inputChannelCount) ch")
            print("  per stream:   \(aggregate.inputStreamChannelCounts)")
            print("\n  expected: microphone \(input.inputChannelCount) ch + tap \(tapChannels) ch"
                  + " = \(input.inputChannelCount + tapChannels) ch")

            diagnoseEngineFormats(aggregateDeviceID: aggregate.deviceID)
        } catch {
            print("\nFAILED: \(error.localizedDescription)")
        }
    }
}
