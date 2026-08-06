import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    private var session = RecordingSession()
    private var recorder: AggregateRecorder?
    private var sessionDirectory: URL?
    private var lastTranscriptURL: URL?

    private var liveMicrophone: LiveTranscriber?
    private var liveSystemAudio: LiveTranscriber?
    private var accumulator = TranscriptAccumulator()
    /// Whether the current run was started by the trigger rather than by the
    /// user. Modal dialogs must never block an unattended machine.
    private var currentRunWasAutomatic = false

    private var sessionLog: SessionLog?
    /// Samples audio sources during a recording, so a silent far side can be
    /// explained afterwards instead of guessed at.
    private var sourceLogTimer: Timer?

    private var detectionTimer: Timer?
    private var trigger = MeetingTrigger(timing: .default)
    /// Monotonic clock for the trigger. Wall time would jump on a clock change
    /// or a wake from sleep and could fire a start or stop spuriously.
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let preferences = PreferenceStore()
    private let store = RecordingStore(baseDirectory: RecordingStore.defaultBaseDirectory())

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.toggleRecording()
        }

        startDetectionTimer()
    }

    // MARK: - Automatic recording

    /// Poll for meeting conditions, but only while the feature is on.
    ///
    /// The timer is not created at all when auto-recording is off, rather than
    /// created and short-circuited. Enumerating Core Audio processes is
    /// currently a suspect in a silent-tap bug, and a timer that runs but does
    /// nothing is indistinguishable from one that is off — which makes it
    /// useless for isolating the cause.
    private func startDetectionTimer() {
        detectionTimer?.invalidate()
        detectionTimer = nil

        guard preferences.autoRecordEnabled else { return }

        // Adopt the new timing without discarding run state. Replacing the
        // trigger outright would forget an in-flight recording, restarting the
        // cap clock every time the settings window closes.
        trigger = trigger.adopting(timing: preferences.autoRecordTiming)

        detectionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleForMeeting() }
        }
    }

    private func sampleForMeeting() {
        guard preferences.autoRecordEnabled else { return }
        // Transcription still running from a previous meeting; starting another
        // recording on top of it would interleave two sessions.
        guard session.state != .transcribing else { return }

        let sample = MeetingDetector.sample(
            meetingBundleIDs: preferences.meetingBundleIDs,
            excludedBundleIDs: preferences.excludedBundleIDs
        )

        switch trigger.observe(meetingDetected: sample.shouldRecord(matching: preferences.autoRecordConditions), at: uptime) {
        case .none:
            break
        case .start:
            guard session.state == .idle else { return }
            beginRun(automatically: true)
        case .stop:
            guard session.state == .recording else { return }
            stopRecording()
        }
    }

    /// One key for both directions: during a meeting there is no time to check
    /// which state the app is in before pressing something.
    private func toggleRecording() {
        switch session.state {
        case .idle:
            beginRun(automatically: false)
        case .recording:
            stopRecording()
        case .transcribing:
            // Already busy; a second press must not queue anything.
            break
        }
    }

    // MARK: - Menus

    /// A `.accessory` app still needs a main menu, otherwise ⌘C/⌘V do not work
    /// inside the settings window's text fields. Same reason as nani-mini.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Splitvox について", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        // `undo:` is delivered through the responder chain to whichever object
        // owns an undo manager; there is no concrete type to write a #selector
        // against, unlike the editing actions below.
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "すべてを選択",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(
            withTitle: "閉じる",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusItem()
    }

    /// Title and menu both derive from `RecordingSession`, so the tested state
    /// machine is the single source of truth for what the user can do.
    private func updateStatusItem() {
        guard let statusItem else { return }
        applyStatusImage(to: statusItem)

        let menu = NSMenu()

        switch session.state {
        case .idle:
            menu.addItem(
                NSMenuItem(title: "録音を開始", action: #selector(startRecording), keyEquivalent: "r")
            )
        case .recording:
            menu.addItem(
                NSMenuItem(title: "録音を停止", action: #selector(stopRecording), keyEquivalent: "r")
            )
        case .transcribing:
            let item = NSMenuItem(title: "文字起こし中…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if lastTranscriptURL != nil {
            menu.addItem(.separator())
            menu.addItem(
                NSMenuItem(
                    title: "最後の書き起こしを開く",
                    action: #selector(openLastTranscript),
                    keyEquivalent: "o"
                )
            )
        }

        if let message = session.lastErrorMessage {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "前回のエラー: \(message)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "録音フォルダを開く",
                action: #selector(openRecordingsFolder),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// Draw the status item from the session's symbol.
    ///
    /// Recording is drawn in red rather than as a template image: it is the one
    /// state where the user needs to notice at a glance that capture is live,
    /// and a monochrome icon in a full menu bar does not carry that.
    private func applyStatusImage(to statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }

        let image = NSImage(
            systemSymbolName: session.statusSymbolName,
            accessibilityDescription: session.accessibilityDescription
        )

        if session.state == .recording {
            let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = image?.withSymbolConfiguration(configuration)
        } else {
            image?.isTemplate = true
            button.image = image
        }

        button.toolTip = session.accessibilityDescription
    }

    // MARK: - Recording

    /// Menu items target this selector directly, so the flag is cleared here
    /// rather than in `toggleRecording` — otherwise a menu-started run would
    /// inherit `true` from the previous automatic one and silently swallow its
    /// error dialogs.
    @objc private func startRecording() {
        beginRun(automatically: false)
    }

    private func beginRun(automatically: Bool) {
        currentRunWasAutomatic = automatically
        Task { await beginRecording() }
    }

    private func beginRecording() async {
        guard session.state == .idle else { return }

        guard await requestMicrophoneAccess() else {
            session.fail("マイクへのアクセスが許可されていません")
            // Without this the trigger still believes a recording is running
            // and would never start the next meeting.
            trigger.recordingBecameInactive(at: uptime)
            updateStatusItem()
            report(
                "マイクへのアクセスが許可されていません。\n\n"
                    + "システム設定 → プライバシーとセキュリティ → マイク で Splitvox を ON に"
                    + "してください。"
            )
            return
        }

        let settings = preferences.current

        if let shortage = describeInsufficientSpace() {
            session.fail(shortage)
            trigger.recordingBecameInactive(at: uptime)
            updateStatusItem()
            report(shortage)
            return
        }

        do {
            let directory = try store.createSessionDirectory(startedAt: Date())
            // Exclusions apply to capture, not only to the trigger. A section
            // titled 除外するアプリ that still records the app would be lying.
            let capturedBundleIDs = settings.meetingBundleIDs.filter {
                !MeetingDetector.isExcluded($0, by: preferences.excludedBundleIDs)
            }

            let newRecorder = try AggregateRecorder(
                bundleIDs: capturedBundleIDs,
                preferredInputUID: settings.inputDeviceUID
            )

            accumulator = TranscriptAccumulator()
            sessionDirectory = directory
            lastTranscriptURL = RecordingStore.transcriptFileURL(in: directory)

            let log = SessionLog(directory: directory)
            sessionLog = log
            log.write("recording started")
            log.write("input device: \(newRecorder.inputDeviceName)")
            log.write("channel layout: mic \(newRecorder.layout.microphoneChannels), "
                      + "tap \(newRecorder.layout.systemAudioChannels)")
            log.write("configured bundle IDs: \(capturedBundleIDs.joined(separator: ", "))")
            if !preferences.excludedBundleIDs.isEmpty {
                log.write("excluded: \(preferences.excludedBundleIDs.joined(separator: ", "))")
            }
            log.write("tap matched \(newRecorder.resolvedProcessCount) process object(s)")
            if let format = newRecorder.tapStreamDescription {
                log.write("tap format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch")
            }
            log.logAudioSources(configured: capturedBundleIDs, excluded: preferences.excludedBundleIDs)

            // Started before recording so the opening seconds are transcribed
            // too. A failure here leaves recording intact: the audio files are
            // still written and can be transcribed afterwards.
            await startLiveTranscription(for: newRecorder)

            try newRecorder.start(
                microphoneURL: RecordingStore.microphoneFileURL(in: directory),
                systemAudioURL: RecordingStore.systemAudioFileURL(in: directory)
            )

            recorder = newRecorder
            _ = session.start()
            // Tell the trigger, so a manual start is not followed by an
            // automatic one, and so the stop countdown is measured from here.
            trigger.recordingBecameActive(at: uptime)
            startSourceLogging(configured: capturedBundleIDs, excluded: preferences.excludedBundleIDs)
        } catch {
            tearDownLiveTranscription()
            session.fail(error.localizedDescription)
            trigger.recordingBecameInactive(at: uptime)
            report("録音を開始できませんでした。\n\n\(error.localizedDescription)")
        }

        updateStatusItem()
    }

    private func startLiveTranscription(for recorder: AggregateRecorder) async {
        guard let microphoneFormat = recorder.microphoneFormat,
              let systemAudioFormat = recorder.systemAudioFormat else { return }

        do {
            // Locale passed in explicitly: Core must not read Storage.
            let locale = preferences.transcriptionLocaleIdentifier
            let microphone = LiveTranscriber(localeIdentifier: locale)
            let systemAudio = LiveTranscriber(localeIdentifier: locale)

            microphone.onSegment = { [weak self] segment in
                Task { @MainActor in self?.appendSegment(segment, from: .me) }
            }
            systemAudio.onSegment = { [weak self] segment in
                Task { @MainActor in self?.appendSegment(segment, from: .them) }
            }

            try await microphone.start(sourceFormat: microphoneFormat)
            try await systemAudio.start(sourceFormat: systemAudioFormat)

            recorder.onMicrophoneBuffer = { [weak microphone] in microphone?.append($0) }
            recorder.onSystemAudioBuffer = { [weak systemAudio] in systemAudio?.append($0) }

            liveMicrophone = microphone
            liveSystemAudio = systemAudio
        } catch {
            // Recording still proceeds; the transcript is produced from the
            // files at stop instead.
            tearDownLiveTranscription()
            NSLog("[Splitvox] live transcription unavailable: \(error.localizedDescription)")
        }
    }

    /// Refuses to start when the volume cannot hold the session.
    ///
    /// Without this the WAVs simply truncate as the disk fills: writes fail
    /// silently, live transcription keeps producing text, and the session ends
    /// looking successful.
    private func describeInsufficientSpace() -> String? {
        let directory = RecordingStore.defaultBaseDirectory()
        guard let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }

        // Roughly 1 GB per hour across both tracks, plus a margin. Only an
        // automatic run is sized against the cap: a deliberate 10-minute
        // recording should not be refused because the cap happens to be 8 hours.
        let hours = currentRunWasAutomatic
            ? preferences.autoRecordTiming.maximumDuration / 3600
            : 1
        let required = Int64((hours + 1) * 1_000_000_000)
        guard available < required else { return nil }

        let availableGB = Double(available) / 1_000_000_000
        let requiredGB = Double(required) / 1_000_000_000
        return String(
            format: "ディスクの空き容量が足りません（空き %.1f GB / 必要 %.0f GB）。\n\n"
                + "録音は1時間あたり約1GBを消費します。"
                + "録音フォルダの古いセッションを削除してください。",
            availableGB, requiredGB
        )
    }

    /// Sample audio sources periodically for the whole recording.
    ///
    /// A single check at the start is not enough: an application can begin
    /// playing minutes in — Zoom starts its meeting host process when the call
    /// connects, not when the app launches.
    private func startSourceLogging(configured: [String], excluded: [String]) {
        sourceLogTimer?.invalidate()
        sourceLogTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sessionLog?.logAudioSources(configured: configured, excluded: excluded)
            }
        }
    }

    private func stopSourceLogging() {
        sourceLogTimer?.invalidate()
        sourceLogTimer = nil
    }

    private func tearDownLiveTranscription() {
        recorder?.onMicrophoneBuffer = nil
        recorder?.onSystemAudioBuffer = nil
        liveMicrophone = nil
        liveSystemAudio = nil
    }

    /// Rewrite the whole transcript rather than appending: coalescing can merge
    /// a new fragment into the previous line, so the file is only correct when
    /// rendered as a whole. It stays small enough that this is free.
    private func appendSegment(_ segment: TranscriptSegment, from speaker: Speaker) {
        guard accumulator.add(segment, from: speaker) else { return }
        writeTranscript()
    }

    private func writeTranscript() {
        guard let url = lastTranscriptURL, !accumulator.isEmpty else { return }
        try? accumulator.markdown().write(to: url, atomically: true, encoding: .utf8)
    }

    @objc private func stopRecording() {
        guard session.state == .recording, let directory = sessionDirectory else { return }

        // Last sample before teardown: whatever was playing at the end is the
        // best evidence of what should have been captured.
        sessionLog?.logAudioSources(
            configured: preferences.meetingBundleIDs,
            excluded: preferences.excludedBundleIDs
        )
        stopSourceLogging()

        if let recorder, recorder.writeFailures > 0 {
            sessionLog?.write("WRITE FAILURES: \(recorder.writeFailures)"
                              + (recorder.firstWriteError.map { " — \($0)" } ?? ""))
        }
        if let recorder {
            sessionLog?.write("callbacks: \(recorder.callbackCount), "
                              + "with tap audio: \(recorder.tapNonSilentCallbacks), "
                              + "buffer layout: \(recorder.observedBufferLayout)")
        }

        recorder?.stop()
        recorder = nil
        _ = session.stop()
        sessionLog?.write("recording stopped")
        updateStatusItem()

        Task { await finishSession(directory: directory) }
    }

    private func finishSession(directory: URL) async {
        // Drain whatever the live transcribers still hold before deciding
        // whether the transcript is usable.
        if liveMicrophone != nil || liveSystemAudio != nil {
            await liveMicrophone?.finish()
            await liveSystemAudio?.finish()
            tearDownLiveTranscription()

            if !accumulator.isEmpty {
                writeTranscript()
                _ = session.finish()
                trigger.recordingBecameInactive(at: uptime)
                updateStatusItem()

                warnIfFarSideSilent(directory: directory)
                sessionLog?.write("done — \(accumulator.me.count + accumulator.them.count) segments")
                sessionLog?.flush()
                sessionLog = nil

                if let url = lastTranscriptURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                return
            }
            // Nothing recognised live — fall through and try the files, which
            // distinguishes "silence" from "the live path failed".
        }

        await transcribeFromFiles(directory: directory)
    }

    private func transcribeFromFiles(directory: URL) async {
        let transcriber = Transcriber(localeIdentifier: preferences.transcriptionLocaleIdentifier)

        do {
            try await transcriber.ensureModelInstalled()

            let me = try await transcriber.transcribe(
                fileURL: RecordingStore.microphoneFileURL(in: directory)
            )
            let them = try await transcriber.transcribe(
                fileURL: RecordingStore.systemAudioFileURL(in: directory)
            )

            let merged = TranscriptMerger.mergeCoalescing(me: me, them: them)
            let markdown = TranscriptMerger.markdown(for: merged)

            let transcriptURL = RecordingStore.transcriptFileURL(in: directory)
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

            lastTranscriptURL = transcriptURL
            _ = session.finish()
            trigger.recordingBecameInactive(at: uptime)
            updateStatusItem()

            NSWorkspace.shared.activateFileViewerSelecting([transcriptURL])
        } catch {
            session.fail(error.localizedDescription)
            // Without this the trigger still believes a recording is running
            // and would never start the next meeting.
            trigger.recordingBecameInactive(at: uptime)
            updateStatusItem()
            // The audio is still on disk, so say where it is rather than
            // letting the recording look lost.
            report(
                "文字起こしに失敗しました。\n\n\(error.localizedDescription)\n\n"
                    + "録音ファイルは残っています:\n\(directory.path)"
            )
        }
    }

    /// Warn when the far side recorded silence.
    ///
    /// This is the one failure that looks like success: the app records, the
    /// transcript fills up with your own speech, and only the other person is
    /// missing. It happened on a real 40-minute Zoom call configured for Chrome
    /// only, and went unnoticed until the meeting was over. Checking the level
    /// costs nothing and turns a wasted meeting into a settings fix.
    private func warnIfFarSideSilent(directory: URL) {
        let url = RecordingStore.systemAudioFileURL(in: directory)
        guard let analysis = try? AudioAnalysis.analyse(url) else { return }

        sessionLog?.write(String(format: "them level: %.1f dBFS",
                                 AudioAnalysis.decibels(analysis.overallRMS)))

        guard analysis.overallRMS <= 0 || AudioAnalysis.decibels(analysis.overallRMS) < -70 else {
            return
        }
        // Always logged, even when the dialog is off: the file is where this
        // gets diagnosed later, and silencing a warning should not also
        // silence the record of it.
        sessionLog?.write("FAR SIDE SILENT — 上の 'NOT captured' 行を確認してください")

        guard preferences.warnOnSilentFarSide else { return }

        let configured = preferences.meetingBundleIDs.joined(separator: "\n")
        report(
            "相手側の音声が録音されていません（無音）。\n\n"
                + "会議アプリのバンドルIDが設定に含まれていない可能性があります。"
                + "設定… →「再生中を検出」を、会議の音が鳴っている状態で押すと追加できます。\n\n"
                + "現在の設定:\n\(configured)\n\n"
                + "録音ファイルは残っています:\n\(directory.path)"
        )
    }

    /// Asked when recording is first attempted rather than at launch, so the
    /// prompt arrives with the reason for it visible.
    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Actions

    /// The only way to see what the app generated.
    ///
    /// Auto-record produces recordings without the user acting, so shipping it
    /// without a route to the files would mean data appearing on their disk
    /// with nothing in the UI acknowledging it.
    @objc private func openRecordingsFolder() {
        let directory = RecordingStore.defaultBaseDirectory()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        NSWorkspace.shared.open(directory)
    }

    @objc private func openLastTranscript() {
        guard let lastTranscriptURL else { return }
        NSWorkspace.shared.open(lastTranscriptURL)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Splitvox 設定"
            window.contentView = NSHostingView(rootView: SettingsView())
            // Reopening a released window crashes; keep it alive between shows.
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        // Required for an .accessory app: it is not activated by clicking the
        // status item alone.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)

        // Picking up a change to the auto-record toggle needs the timer rebuilt,
        // and closing Settings is the moment that change is finished.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: settingsWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.startDetectionTimer() }
        }
    }

    @objc private func quit() {
        recorder?.stop()
        NSApp.terminate(nil)
    }

    /// Reports a problem without blocking.
    ///
    /// `runModal()` spins a modal run loop, which stops the detection timer
    /// from firing. On an unattended machine — exactly what auto-record plus
    /// launch-at-login creates — one failure would deafen the app until
    /// somebody clicked OK. Automatic runs therefore only log.
    private func report(_ text: String) {
        sessionLog?.write("notice: \(text.replacingOccurrences(of: "\n", with: " "))")
        guard !currentRunWasAutomatic else {
            NSLog("[Splitvox] %@", text)
            return
        }
        showMessage(text)
    }

    private func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Splitvox"
        alert.informativeText = text
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
