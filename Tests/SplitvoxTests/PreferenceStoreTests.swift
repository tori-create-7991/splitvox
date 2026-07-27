import Foundation
import Testing
@testable import Splitvox

@Suite("PreferenceStore")
struct PreferenceStoreTests {

    /// Each test gets its own suite name so stored values cannot leak between
    /// them or into the real user defaults.
    private func makeStore(_ suite: String = #function) -> (PreferenceStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PreferenceStore(defaults: defaults), defaults)
    }

    @Test("An unconfigured store reports the built-in meeting applications")
    func unconfiguredStoreReportsDefaults() {
        let (store, _) = makeStore()

        #expect(store.meetingBundleIDs == Config.defaultMeetingBundleIDs)
        #expect(store.inputDeviceUID == nil)
    }

    @Test("Stored bundle IDs are read back")
    func storedBundleIDsAreReadBack() {
        let (store, _) = makeStore()

        store.meetingBundleIDs = ["us.zoom.xos", "us.zoom.caphost"]

        #expect(store.meetingBundleIDs == ["us.zoom.xos", "us.zoom.caphost"])
    }

    /// An empty list would tap nothing and record silence into them.wav, which
    /// looks identical to a broken recording. Falling back keeps the app usable.
    @Test("Clearing the bundle ID list falls back to the defaults instead of capturing nothing")
    func clearingBundleIDsFallsBackToDefaults() {
        let (store, _) = makeStore()

        store.meetingBundleIDs = []

        #expect(store.meetingBundleIDs == Config.defaultMeetingBundleIDs)
    }

    @Test("Blank entries are discarded so a stray newline cannot break the tap")
    func blankEntriesAreDiscarded() {
        let (store, _) = makeStore()

        store.meetingBundleIDs = ["com.google.Chrome", "   ", "", "com.google.Chrome.helper"]

        #expect(store.meetingBundleIDs == ["com.google.Chrome", "com.google.Chrome.helper"])
    }

    @Test("Selecting an input device is remembered, and clearing it returns to the system default")
    func inputDeviceSelectionRoundTrips() {
        let (store, _) = makeStore()

        store.inputDeviceUID = "BuiltInMicrophoneDevice"
        #expect(store.inputDeviceUID == "BuiltInMicrophoneDevice")

        store.inputDeviceUID = nil
        #expect(store.inputDeviceUID == nil)
    }

    @Test("A snapshot stays stable while the stored values change underneath")
    func snapshotStaysStableWhileStoredValuesChange() {
        let (store, _) = makeStore()
        store.meetingBundleIDs = ["com.google.Chrome"]

        let snapshot = store.current
        store.meetingBundleIDs = ["us.zoom.xos"]

        #expect(snapshot.meetingBundleIDs == ["com.google.Chrome"])
    }
}
