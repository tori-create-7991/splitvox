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
        static let autoRecordCondition = "autoRecordCondition"
        static let startAfter = "autoRecordStartAfter"
        static let stopAfter = "autoRecordStopAfter"
        static let maximumDuration = "autoRecordMaximumDuration"
        static let transcriptionLocale = "transcriptionLocale"
        static let warnOnSilentFarSide = "warnOnSilentFarSide"
        static let autoRecordAcknowledged = "autoRecordAcknowledged"
        static let excludedBundleIDs = "excludedBundleIDs"
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

    /// Which signals must hold before a recording starts.
    ///
    /// Stored as the raw bitmask. An absent value means "never configured" and
    /// falls back to the default, which is not the same as an explicitly empty
    /// set — that one disables the trigger.
    var autoRecordConditions: AutoRecordConditions {
        get {
            guard defaults.object(forKey: Key.autoRecordCondition) != nil else {
                return .default
            }
            return AutoRecordConditions(rawValue: defaults.integer(forKey: Key.autoRecordCondition))
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.autoRecordCondition) }
    }

    /// Timing for the automatic trigger. Absent values fall back to defaults
    /// rather than to zero, which would start and stop constantly.
    var autoRecordTiming: AutoRecordTiming {
        get {
            var timing = AutoRecordTiming.default
            // Clamped to the offered choices. A stored 0 for maximumDuration —
            // reachable via `defaults write` or a future migration — would make
            // the cap fire on the first tick after every start, producing a
            // stream of 3-second sessions.
            timing.startAfter = Self.clamped(
                defaults, Key.startAfter,
                to: AutoRecordTiming.startChoices, default: timing.startAfter
            )
            timing.stopAfter = Self.clamped(
                defaults, Key.stopAfter,
                to: AutoRecordTiming.stopChoices, default: timing.stopAfter
            )
            timing.maximumDuration = Self.clamped(
                defaults, Key.maximumDuration,
                to: AutoRecordTiming.maximumChoices, default: timing.maximumDuration
            )
            return timing
        }
        nonmutating set {
            defaults.set(newValue.startAfter, forKey: Key.startAfter)
            defaults.set(newValue.stopAfter, forKey: Key.stopAfter)
            defaults.set(newValue.maximumDuration, forKey: Key.maximumDuration)
        }
    }

    /// Language the recogniser is asked for. A meeting held in another language
    /// transcribes as noise otherwise.
    var transcriptionLocaleIdentifier: String {
        get {
            let stored = defaults.string(forKey: Key.transcriptionLocale)?
                .trimmingCharacters(in: .whitespaces)
            return Self.validLocale(stored) ?? Config.transcriptionLocaleIdentifier
        }
        nonmutating set { defaults.set(newValue, forKey: Key.transcriptionLocale) }
    }

    /// Show a dialog when the far side recorded silence.
    ///
    /// On by default because that failure looks like success — the transcript
    /// fills with your own speech and only the other person is missing, which
    /// went unnoticed for a whole 40-minute meeting once. Off is offered
    /// because once the cause is known the dialog is just noise.
    var warnOnSilentFarSide: Bool {
        get {
            guard defaults.object(forKey: Key.warnOnSilentFarSide) != nil else { return true }
            return defaults.bool(forKey: Key.warnOnSilentFarSide)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.warnOnSilentFarSide) }
    }

    /// Applications that must never trigger a recording, even when they are
    /// playing and otherwise match.
    ///
    /// Needed because the include list is coarse: capturing Chrome also
    /// captures every notification chime a web app makes through it. Matching
    /// is by prefix, so the parent bundle ID covers its helpers.
    var excludedBundleIDs: [String] {
        get { Self.clean(defaults.stringArray(forKey: Key.excludedBundleIDs) ?? []) }
        nonmutating set { defaults.set(Self.clean(newValue), forKey: Key.excludedBundleIDs) }
    }

    /// Locale must be one this build actually offers, so the Settings picker
    /// always has a matching tag and cannot render blank.
    private static func validLocale(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return Config.transcriptionLocales.contains { $0.identifier == identifier }
            ? identifier
            : nil
    }

    /// Whether the user has seen the one-time notice about unattended
    /// recording. Enabling auto-record is the moment they take on
    /// responsibility for recording other people; it should not pass silently.
    var autoRecordAcknowledged: Bool {
        get { defaults.bool(forKey: Key.autoRecordAcknowledged) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoRecordAcknowledged) }
    }

    var current: Preferences {
        Preferences(
            meetingBundleIDs: meetingBundleIDs,
            inputDeviceUID: inputDeviceUID,
            autoRecordEnabled: autoRecordEnabled
        )
    }

    /// Reads a stored interval, falling back to `default` when absent or
    /// outside the offered range.
    private static func clamped(
        _ defaults: UserDefaults,
        _ key: String,
        to choices: [TimeInterval],
        default fallback: TimeInterval
    ) -> TimeInterval {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let stored = defaults.double(forKey: key)
        guard let lowest = choices.min(), let highest = choices.max(),
              stored >= lowest, stored <= highest else { return fallback }
        return stored
    }

    private static func clean(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
