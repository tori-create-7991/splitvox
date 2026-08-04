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
    @State private var launchAtLogin = false
    @State private var loginItemMessage: String?

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
                    }

                Text(
                    "ヘッドセット（内蔵マイク以外が既定の入力）が有効で、かつ上記のアプリが"
                        + "音を出しているときに開始します。動画の再生も記録されます。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("条件が約5秒続いたら開始し、約30秒途切れたら停止します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func load() {
        bundleIDText = store.meetingBundleIDs.joined(separator: "\n")
        inputDevices = AudioDeviceLookup.availableInputDevices()
        installedApps = InstalledAppLookup.scan()
        autoRecordEnabled = store.autoRecordEnabled

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
        let playing = Set(AudioProcessLookup.bundleIDsProducingOutput())
            .subtracting(["com.ryo.splitvox"])
            .sorted()

        guard !playing.isEmpty else {
            detectionMessage = "音を出しているアプリが見つかりません。会議やビデオを再生した状態で押してください。"
            return
        }

        addBundleIDs(playing)
        detectionMessage = "検出: \(playing.joined(separator: ", "))"
    }

    private func save() {
        store.meetingBundleIDs = bundleIDText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        store.inputDeviceUID = selectedInputUID == Self.systemDefaultTag ? nil : selectedInputUID

        // Re-read so the field shows what was actually kept, including the
        // fallback to defaults when the list was emptied.
        bundleIDText = store.meetingBundleIDs.joined(separator: "\n")
        savedMessage = "保存しました"
    }
}
