import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {

    private let store = PreferenceStore()

    @State private var bundleIDText: String = ""
    @State private var selectedInputUID: String = SettingsView.systemDefaultTag
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var installedApps: [InstalledApp] = []
    @State private var savedMessage: String?
    @State private var detectionMessage: String?
    @State private var autoRecordEnabled = false
    @State private var autoRecordConditions: AutoRecordConditions = .default
    @State private var startAfter = AutoRecordTiming.default.startAfter
    @State private var stopAfter = AutoRecordTiming.default.stopAfter
    @State private var maximumDuration = AutoRecordTiming.default.maximumDuration
    @State private var transcriptionLocale = Config.transcriptionLocaleIdentifier
    @State private var excludedText: String = ""
    @State private var warnOnSilentFarSide = true
    @State private var launchAtLogin = false
    @State private var loginItemMessage: String?
    @State private var localHooks: [LocalHook] = []
    @State private var localHooksError: String?
    @State private var timeoutDrafts: [UUID: String] = [:]
    @State private var recordingStartedWebhookURL = ""
    @State private var recordingStoppedWebhookURL = ""

    /// Sentinel for "follow the system default", which is stored as nil.
    private static let systemDefaultTag = ""

    var body: some View {
        Form {
            Section("会議アプリ") {
                Text("音声を取り込むアプリのバンドルID。1行に1つ。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $bundleIDText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .border(Color.secondary.opacity(0.3))

                Text(
                    "Chrome は音声を別プロセスから再生するため、本体とヘルパーの両方が必要です。"
                        + "空にすると初期値に戻ります。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Menu("プリセット") {
                        ForEach(Config.knownMeetingApps) { app in
                            Button(app.name) { addBundleIDs(app.bundleIDs) }
                        }
                    }
                    .frame(maxWidth: 110)

                    // Reads /Applications, so anything installed can be added
                    // without knowing its bundle ID. Nested apps come along,
                    // which is where several apps actually play audio from.
                    Menu("インストール済み") {
                        ForEach(installedApps) { app in
                            Button(helperLabel(for: app)) { addBundleIDs(app.allBundleIDs) }
                        }
                    }
                    .frame(maxWidth: 140)

                    Button("再生中を検出") { detectPlayingApps() }
                }

                if let detectionMessage {
                    Text(detectionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("除外するアプリ") {
                Text("ここに書いたアプリは録音の対象から外れ、自動記録の合図にもなりません。1行に1つ。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $excludedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .border(Color.secondary.opacity(0.3))
                    // Saved on change like every other setting here. A control
                    // whose job is to *prevent* recording must not fail in the
                    // direction that records more when the window is closed.
                    .onChange(of: excludedText) { _, _ in saveExclusions() }

                Text(
                    "前方一致で判定するので、notion.id と書けば notion.id.helper も除外されます。"
                        + "通知音を出すのは本体ではなくヘルパーであることが多いためです。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("再生中のアプリを除外に追加") { excludePlayingApps() }
            }

            Section("マイク") {
                Picker("入力デバイス", selection: $selectedInputUID) {
                    Text("システムの既定").tag(Self.systemDefaultTag)
                    ForEach(inputDevices, id: \.uid) { device in
                        Text("\(device.name) (\(device.inputChannelCount) ch)").tag(device.uid)
                    }
                }

                Text("仮想マイクを選ぶとノイズ除去済みの音声を録れますが、そのアプリが停止すると録音も止まります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("起動") {
                Toggle("ログイン時に起動する", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        applyLaunchAtLogin(value)
                    }

                if let loginItemMessage {
                    Text(loginItemMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if LoginItem.status == .requiresApproval {
                    Button("システム設定を開いて許可する") {
                        LoginItem.openLoginItemsSettings()
                    }
                }
            }

            Section("自動記録") {
                Toggle("会議を検出したら自動で録音する", isOn: $autoRecordEnabled)
                    .onChange(of: autoRecordEnabled) { _, value in
                        store.autoRecordEnabled = value
                        if value { acknowledgeAutoRecordOnce() }
                    }

                Text("開始条件（有効にしたものをすべて満たしたとき）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(AutoRecordConditions.orderedOptions, id: \.rawValue) { condition in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(condition.label, isOn: binding(for: condition))
                            .disabled(!autoRecordEnabled)
                        Text(condition.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Reachable two ways: the user turns every condition off, or a
                // stored set written by a newer build is masked down to nothing
                // on downgrade. Both leave an enabled toggle that never fires,
                // with no other indication of why.
                if autoRecordEnabled && autoRecordConditions.isEmpty {
                    Text("条件が1つも有効になっていないため、自動記録は動作しません。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("開始まで", selection: $startAfter) {
                    ForEach(AutoRecordTiming.startChoices, id: \.self) { value in
                        Text(AutoRecordTiming.describeSeconds(value)).tag(value)
                    }
                }
                .disabled(!autoRecordEnabled)
                .onChange(of: startAfter) { _, _ in saveTiming() }

                Picker("停止まで", selection: $stopAfter) {
                    ForEach(AutoRecordTiming.stopChoices, id: \.self) { value in
                        Text(AutoRecordTiming.describeSeconds(value)).tag(value)
                    }
                }
                .disabled(!autoRecordEnabled)
                .onChange(of: stopAfter) { _, _ in saveTiming() }

                Text("停止までが短いと、会話が途切れるたびに会議が分割されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("1回の上限", selection: $maximumDuration) {
                    ForEach(AutoRecordTiming.maximumChoices, id: \.self) { value in
                        Text(AutoRecordTiming.describeSeconds(value)).tag(value)
                    }
                }
                .disabled(!autoRecordEnabled)
                .onChange(of: maximumDuration) { _, _ in saveTiming() }

                Text("上限に達すると停止し、条件が一度途切れるまで再開しません。1時間あたり約1GBを消費します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文字起こし") {
                Picker("言語", selection: $transcriptionLocale) {
                    ForEach(Config.transcriptionLocales, id: \.identifier) { locale in
                        Text(locale.label).tag(locale.identifier)
                    }
                }
                .onChange(of: transcriptionLocale) { _, value in
                    store.transcriptionLocaleIdentifier = value
                }

                Text("端末にモデルが無い言語は、初回の文字起こし時にダウンロードされます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通知") {
                Toggle("相手側が無音のときに警告する", isOn: $warnOnSilentFarSide)
                    .onChange(of: warnOnSilentFarSide) { _, value in
                        store.warnOnSilentFarSide = value
                    }

                Text("オフにしても session.log には記録されるので、後から原因を追えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ローカルフック") {
                Text("録音開始時・文字起こし完了時に、複数の外部コマンドを独立して実行します。追加・編集後は保存してください。")
                    .font(.caption).foregroundStyle(.secondary)
                if let localHooksError {
                    Text(localHooksError).foregroundStyle(.red)
                    Button("設定を再読み込み") { loadHooks() }
                } else {
                    ForEach($localHooks) { $hook in
                        LocalHookEditor(hook: $hook, timeoutText: timeoutBinding(for: hook)) {
                            localHooks.removeAll { $0.id == hook.id }
                        }
                        Divider()
                    }
                    Button("コマンドを追加") {
                        localHooks.append(LocalHook(name: "新しいコマンド", enabled: false))
                    }
                }
                Text("コマンドは /bin/zsh -lc で実行します。標準入力は閉じ、標準出力・標準エラーは破棄します。必要な診断はスクリプト側でファイルへ保存してください。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("環境変数: SPLITVOX_HOOK_EVENT、SPLITVOX_SESSION_DIRECTORY、SPLITVOX_RECORDING_STARTED_AT、SPLITVOX_HOOK_OCCURRED_AT。コマンドに認証情報を書くとUserDefaultsに平文保存されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Webhook") {
                TextField("録音開始時のURL", text: $recordingStartedWebhookURL)
                TextField("文字起こし完了時のURL", text: $recordingStoppedWebhookURL)
                Text("コマンドとは独立して、同じイベントのメタデータをJSON POSTします。空欄で無効です。URLに含めた認証情報はUserDefaultsに平文保存されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("ショートカット") {
                KeyboardShortcuts.Recorder("録音の開始 / 停止", name: .toggleRecording)

                Text("メニューバーのアイコンが他のアイコンに埋もれても、キー操作で録音できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)

                    if let savedMessage {
                        Text(savedMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: load)
    }

    private func timeoutBinding(for hook: LocalHook) -> Binding<String> {
        Binding(get: { timeoutDrafts[hook.id] ?? String(hook.timeoutSeconds) },
                set: { timeoutDrafts[hook.id] = $0 })
    }

    private func loadHooks() {
        do {
            localHooks = try store.loadLocalHooks()
            timeoutDrafts = Dictionary(uniqueKeysWithValues: localHooks.map { ($0.id, String($0.timeoutSeconds)) })
            localHooksError = nil
        } catch {
            localHooks = []
            localHooksError = error.localizedDescription
        }
    }

    private func load() {
        loadHooks()
        bundleIDText = store.meetingBundleIDs.joined(separator: "\n")
        inputDevices = AudioDeviceLookup.availableInputDevices()
        installedApps = InstalledAppLookup.scan()
        autoRecordEnabled = store.autoRecordEnabled
        autoRecordConditions = store.autoRecordConditions

        let timing = store.autoRecordTiming
        startAfter = timing.startAfter
        stopAfter = timing.stopAfter
        maximumDuration = timing.maximumDuration
        transcriptionLocale = store.transcriptionLocaleIdentifier
        warnOnSilentFarSide = store.warnOnSilentFarSide
        excludedText = store.excludedBundleIDs.joined(separator: "\n")
        let startedHook = store.recordingHook(for: .started)
        recordingStartedWebhookURL = startedHook.webhookURL
        let stoppedHook = store.recordingHook(for: .stopped)
        recordingStoppedWebhookURL = stoppedHook.webhookURL

        // Read from the system rather than from our own defaults: macOS is the
        // authority here, and the user can revoke it in System Settings.
        launchAtLogin = LoginItem.status == .enabled
        loginItemMessage = describeLoginItemStatus()

        // A device that has been unplugged since it was chosen falls back to
        // the system default rather than showing a blank selection.
        let stored = store.inputDeviceUID
        selectedInputUID = inputDevices.contains { $0.uid == stored }
            ? (stored ?? Self.systemDefaultTag)
            : Self.systemDefaultTag
    }

    /// Shows how many extra bundle IDs come with an app, since that is the part
    /// users cannot guess (LINE calls, Zoom meeting hosts, browser helpers).
    private func helperLabel(for app: InstalledApp) -> String {
        app.helperBundleIDs.isEmpty
            ? app.name
            : "\(app.name)  (+\(app.helperBundleIDs.count))"
    }

    /// Each toggle reads and writes one bit of the stored set.
    private func binding(for condition: AutoRecordConditions) -> Binding<Bool> {
        Binding(
            get: { autoRecordConditions.contains(condition) },
            set: { isOn in
                if isOn {
                    autoRecordConditions.insert(condition)
                } else {
                    autoRecordConditions.remove(condition)
                }
                store.autoRecordConditions = autoRecordConditions
            }
        )
    }

    /// Adds whatever is playing now to the exclusion list.
    ///
    /// The counterpart of 再生中を検出: the same measurement, used to rule an
    /// application out rather than in.
    private func excludePlayingApps() {
        let playing = Set(AudioProcessLookup.bundleIDsProducingOutput().bundleIDs)
            .subtracting([Config.bundleIdentifier])
            .sorted()

        guard !playing.isEmpty else {
            detectionMessage = "音を出しているアプリが見つかりません。"
            return
        }

        var current = excludedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let added = playing.filter { !current.contains($0) }
        guard !added.isEmpty else {
            detectionMessage = "すでに除外されています"
            return
        }

        current.append(contentsOf: added)
        excludedText = current.joined(separator: "\n")
        detectionMessage = "除外に追加: \(added.joined(separator: ", "))"
    }

    /// Shown once, the first time auto-record is switched on.
    private func acknowledgeAutoRecordOnce() {
        guard !store.autoRecordAcknowledged else { return }
        store.autoRecordAcknowledged = true

        let alert = NSAlert()
        alert.messageText = "自動記録を有効にしました"
        alert.informativeText = """
            条件を満たすと、操作しなくても録音が始まります。

            ・会議相手の音声も録音されます
            ・相手に通知は行われません
            ・録音の可否と告知は、あなたの責任で判断してください

            録音されたものは、メニューバーの「録音フォルダを開く」から\
            いつでも確認・削除できます。
            """
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func saveExclusions() {
        store.excludedBundleIDs = excludedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func saveTiming() {
        store.autoRecordTiming = AutoRecordTiming(
            startAfter: startAfter,
            stopAfter: stopAfter,
            maximumDuration: maximumDuration
        )
    }

    private func describeLoginItemStatus() -> String? {
        switch LoginItem.status {
        case .enabled, .disabled:
            return nil
        case .requiresApproval:
            return "システム設定での許可が必要です。"
        case .unavailable:
            return "この起動方法では設定できません（ビルドした .app から起動してください）。"
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        switch LoginItem.setEnabled(enabled) {
        case .success:
            loginItemMessage = describeLoginItemStatus()
        case .failure(let error):
            // Reflect what actually happened rather than leaving the toggle
            // showing a state the system did not accept.
            launchAtLogin = LoginItem.status == .enabled
            loginItemMessage = "設定できませんでした: \(error.localizedDescription)"
        }
    }

    private func addBundleIDs(_ ids: [String]) {
        var current = bundleIDText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let added = ids.filter { !current.contains($0) }
        guard !added.isEmpty else {
            detectionMessage = "すでに追加されています"
            return
        }

        current.append(contentsOf: added)
        bundleIDText = current.joined(separator: "\n")
        detectionMessage = "\(added.count) 件追加しました（保存が必要です）"
    }

    /// Reads which processes are producing output right now.
    ///
    /// The preset list is partly guesswork — helper-process bundle IDs are not
    /// documented and differ per app version. Measuring the running system is
    /// the only reliable way to get them, so it is offered directly here.
    private func detectPlayingApps() {
        let playing = Set(AudioProcessLookup.bundleIDsProducingOutput().bundleIDs)
            .subtracting([Config.bundleIdentifier])
            .sorted()

        guard !playing.isEmpty else {
            detectionMessage = "音を出しているアプリが見つかりません。会議やビデオを再生した状態で押してください。"
            return
        }

        addBundleIDs(playing)
        detectionMessage = "検出: \(playing.joined(separator: ", "))"
    }

    private func save() {
        do {
            for value in [recordingStartedWebhookURL, recordingStoppedWebhookURL] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    guard let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                        throw LocalHookFailure("WebhookにはhttpまたはhttpsのURLを入力してください。")
                    }
                }
            }
            // A failed read must not overwrite an unknown document with [].
            if localHooksError == nil {
                var validated = localHooks
                for index in validated.indices {
                    validated[index].timeoutSeconds = try LocalHookDraftValidation.timeout(
                        timeoutDrafts[validated[index].id] ?? String(validated[index].timeoutSeconds)
                    )
                }
                try store.saveLocalHooks(validated)
                localHooks = validated
            }
        } catch {
            savedMessage = error.localizedDescription
            return
        }
        store.meetingBundleIDs = bundleIDText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        store.inputDeviceUID = selectedInputUID == Self.systemDefaultTag ? nil : selectedInputUID
        store.setWebhookURL(recordingStartedWebhookURL, for: .started)
        store.setWebhookURL(recordingStoppedWebhookURL, for: .stopped)

        // Re-read so the field shows what was actually kept, including the
        // fallback to defaults when the list was emptied.
        bundleIDText = store.meetingBundleIDs.joined(separator: "\n")
        excludedText = store.excludedBundleIDs.joined(separator: "\n")
        savedMessage = localHooksError == nil ? "保存しました" : "Webhookと一般設定を保存しました。ローカルフックの読込エラーは未解決です。"
    }
}
