import AppKit

/// A modeless picker keeps the menu-bar app and the next recording usable.
@MainActor
final class NotionNotePicker: NSObject, NSWindowDelegate, Identifiable {
    let id = UUID()
    private let window: NSWindow
    private let popup = NSPopUpButton()
    private var completion: ((String?) -> Void)?

    init(notes: [NotionNote], source: String, startedAt: Date, completion: @escaping (String?) -> Void) {
        self.completion = completion
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "文字起こしの保存先を選択"
        window.isReleasedWhenClosed = false
        window.delegate = self
        popup.menu = Self.makeMenu(notes: notes)
        popup.selectItem(at: 0)
        popup.setAccessibilityLabel("保存先Meeting Note")
        let date = DateFormatter.localizedString(from: startedAt, dateStyle: .short, timeStyle: .medium)
        let recording = NSTextField(labelWithString: "送信元: \(date) / \(source)")
        recording.frame = NSRect(x: 20, y: 147, width: 500, height: 24)
        recording.lineBreakMode = .byTruncatingMiddle
        window.contentView?.addSubview(recording)
        popup.frame = NSRect(x: 20, y: 70, width: 500, height: 30)
        let label = NSTextField(labelWithString: "同じ時間帯のMeeting Noteが複数あります。")
        label.frame = NSRect(x: 20, y: 120, width: 500, height: 24)
        let send = NSButton(title: "このノートへ保存", target: self, action: #selector(choose))
        send.frame = NSRect(x: 350, y: 20, width: 170, height: 32)
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 225, y: 20, width: 120, height: 32)
        [label, popup, send, cancel].forEach { window.contentView?.addSubview($0) }
    }

    func show() { window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    static func makeMenu(notes: [NotionNote]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        for note in notes {
            let item = NSMenuItem(title: "\(formatter.string(from: note.date)) — \(note.title)", action: nil, keyEquivalent: "")
            item.representedObject = note.id
            menu.addItem(item)
        }
        return menu
    }
    @objc private func choose() { finish(popup.selectedItem?.representedObject as? String) }
    @objc private func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func finish(_ result: String?) {
        guard let completion else { return }
        self.completion = nil
        window.close()
        completion(result)
    }
}
