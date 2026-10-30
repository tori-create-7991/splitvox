import SwiftUI

struct LocalHookEditor: View {
    @Binding var hook: LocalHook
    @Binding var timeoutText: String
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("有効", isOn: $hook.enabled)
                TextField("名前", text: $hook.name)
                    .accessibilityLabel("フックの名前")
                Button("削除", action: remove)
                    .accessibilityLabel("このフックを削除")
            }
            Text("ID: " + hook.id.uuidString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Picker("イベント", selection: $hook.event) {
                Text("録音開始時").tag(RecordingHookEvent.started)
                Text("文字起こし完了時").tag(RecordingHookEvent.stopped)
            }
            TextField("ローカルコマンド", text: $hook.command, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2...6)
                .accessibilityLabel("実行するローカルコマンド")
            TextField("タイムアウト（秒、1〜3600）", text: $timeoutText)
                .accessibilityLabel("タイムアウト秒数")
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 4)
    }
}
