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

    private let preferences = PreferenceStore()
    private let store = RecordingStore(baseDirectory: RecordingStore.defaultBaseDirectory())

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.toggleRecording()
        }
    }

    /// One key for both directions: during a meeting there is no time to check
    /// which state the app is in before pressing something.
    private func toggleRecording() {
        switch session.state {
        case .idle:
            startRecording()
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

    @objc private func startRecording() {
        Task { await beginRecording() }
    }

    private func beginRecording() async {
        guard session.state == .idle else { return }

        guard await requestMicrophoneAccess() else {
            session.fail("マイクへのアクセスが許可されていません")
            updateStatusItem()
            showMessage(
                "マイクへのアクセスが許可されていません。\n\n"
                    + "システム設定 → プライバシーとセキュリティ → マイク で Splitvox を ON に"
                    + "してください。"
            )
            return
        }

        let settings = preferences.current

        do {
            let directory = try store.createSessionDirectory(startedAt: Date())
            let newRecorder = try AggregateRecorder(
                bundleIDs: settings.meetingBundleIDs,
                preferredInputUID: settings.inputDeviceUID
            )
            try newRecorder.start(
                microphoneURL: RecordingStore.microphoneFileURL(in: directory),
                systemAudioURL: RecordingStore.systemAudioFileURL(in: directory)
            )

            recorder = newRecorder
            sessionDirectory = directory
            _ = session.start()
        } catch {
            session.fail(error.localizedDescription)
            showMessage("録音を開始できませんでした。\n\n\(error.localizedDescription)")
        }

        updateStatusItem()
    }

    @objc private func stopRecording() {
        guard session.state == .recording, let directory = sessionDirectory else { return }

        recorder?.stop()
        recorder = nil
        _ = session.stop()
        updateStatusItem()

        Task { await finishSession(directory: directory) }
    }

    private func finishSession(directory: URL) async {
        let transcriber = Transcriber()

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
            updateStatusItem()

            NSWorkspace.shared.activateFileViewerSelecting([transcriptURL])
        } catch {
            session.fail(error.localizedDescription)
            updateStatusItem()
            // The audio is still on disk, so say where it is rather than
            // letting the recording look lost.
            showMessage(
                "文字起こしに失敗しました。\n\n\(error.localizedDescription)\n\n"
                    + "録音ファイルは残っています:\n\(directory.path)"
            )
        }
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
    }

    @objc private func quit() {
        recorder?.stop()
        NSApp.terminate(nil)
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
