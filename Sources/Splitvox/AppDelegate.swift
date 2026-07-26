import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "●"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
