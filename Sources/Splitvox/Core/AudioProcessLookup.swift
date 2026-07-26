import CoreAudio
import Foundation

/// Resolves Core Audio process objects, which is how a tap names the
/// applications it captures.
///
/// The shape of these accessors is the one proven by
/// `Tools/audio-process-watch.swift`, which is also the tool to run when the
/// right bundle IDs for a machine are unknown.
enum AudioProcessLookup {

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func allProcessObjectIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func bundleID(of object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func isProducingOutput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    /// Process objects whose bundle ID is in `bundleIDs`.
    ///
    /// A bundle ID can match more than one object: Chrome registers its audio
    /// helper separately from the browser process, and both may be present.
    static func processObjectIDs(forBundleIDs bundleIDs: [String]) -> [AudioObjectID] {
        let wanted = Set(bundleIDs)
        return allProcessObjectIDs().filter { object in
            guard let bundle = bundleID(of: object) else { return false }
            return wanted.contains(bundle)
        }
    }

    /// Bundle IDs currently producing output, for diagnostics and for telling
    /// the user which application to add when a recording captured silence.
    static func bundleIDsProducingOutput() -> [String] {
        allProcessObjectIDs()
            .filter(isProducingOutput)
            .compactMap(bundleID(of:))
    }
}
