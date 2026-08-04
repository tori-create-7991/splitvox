import Foundation

/// A consistent view of the settings, taken at one instant.
///
/// A recording reads several settings while starting; a snapshot keeps them
/// from changing halfway through if the user is editing the settings window.
struct Preferences: Equatable {
    let meetingBundleIDs: [String]
    let inputDeviceUID: String?
    let autoRecordEnabled: Bool
}

/// User-changeable settings. `Config` holds the values fixed at build time.
///
/// `UserDefaults` is injected so tests can isolate themselves; `nonmutating
/// set` lets a `let` store still write, as in nani-mini's
/// `TranslationPreferenceStore`.
struct PreferenceStore {

    private enum Key {
        static let meetingBundleIDs = "meetingBundleIDs"
        static let inputDeviceUID = "inputDeviceUID"
        static let autoRecordEnabled = "autoRecordEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Applications whose output is captured.
    ///
    /// Falls back to the built-in list when the stored value is empty: an empty
    /// tap records silence into `them.wav`, which is indistinguishable from a
    /// broken recording and would send the user hunting for the wrong bug.
    var meetingBundleIDs: [String] {
        get {
            let stored = defaults.stringArray(forKey: Key.meetingBundleIDs) ?? []
            let cleaned = Self.clean(stored)
            return cleaned.isEmpty ? Config.defaultMeetingBundleIDs : cleaned
        }
        nonmutating set {
            defaults.set(Self.clean(newValue), forKey: Key.meetingBundleIDs)
        }
    }

    /// Preferred microphone. `nil` means follow the system default input.
    var inputDeviceUID: String? {
        get {
            let stored = defaults.string(forKey: Key.inputDeviceUID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty ?? true) ? nil : stored
        }
        nonmutating set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.set(newValue, forKey: Key.inputDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.inputDeviceUID)
            }
        }
    }

    /// Start and stop recording automatically when a meeting is detected.
    ///
    /// Off by default: this starts recording without the user asking, so it is
    /// opted into rather than sprung on someone.
    var autoRecordEnabled: Bool {
        get { defaults.bool(forKey: Key.autoRecordEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoRecordEnabled) }
    }

    var current: Preferences {
        Preferences(
            meetingBundleIDs: meetingBundleIDs,
            inputDeviceUID: inputDeviceUID,
            autoRecordEnabled: autoRecordEnabled
        )
    }

    private static func clean(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
