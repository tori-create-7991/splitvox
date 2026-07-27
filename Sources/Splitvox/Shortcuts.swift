import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Start or stop recording without touching the menu bar.
    ///
    /// ⌥⌘R by default: the status item can be pushed off a crowded menu bar
    /// entirely (a MacBook notch makes this easy to hit), and hunting for it
    /// mid-meeting is the wrong moment to discover that.
    static let toggleRecording = Self(
        "toggleRecording",
        default: .init(.r, modifiers: [.option, .command])
    )
}
