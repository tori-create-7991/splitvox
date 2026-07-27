import SwiftUI

struct SettingsView: View {

    private let store = PreferenceStore()

    @State private var bundleIDText: String = ""
    @State private var selectedInputUID: String = SettingsView.systemDefaultTag
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var savedMessage: String?

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

        // A device that has been unplugged since it was chosen falls back to
        // the system default rather than showing a blank selection.
        let stored = store.inputDeviceUID
        selectedInputUID = inputDevices.contains { $0.uid == stored }
            ? (stored ?? Self.systemDefaultTag)
            : Self.systemDefaultTag
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
