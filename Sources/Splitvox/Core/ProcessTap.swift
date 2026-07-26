import CoreAudio
import Foundation

enum ProcessTapError: LocalizedError {
    case creationFailed(OSStatus)
    case uidUnavailable

    var errorDescription: String? {
        switch self {
        case .creationFailed(let status):
            return "システム音声のタップを作成できませんでした (OSStatus \(status))"
        case .uidUnavailable:
            return "作成したタップのUIDを取得できませんでした"
        }
    }
}

/// A Core Audio process tap capturing the output of the meeting application.
///
/// This is the piece that makes speaker separation deterministic: the far end
/// is captured here, the local microphone is captured separately, and the two
/// never mix. Tools that tap the whole system output get one blended stream and
/// have to guess who spoke.
final class ProcessTap {

    let tapID: AudioObjectID
    /// UID used to place this tap inside an aggregate device.
    let uid: String

    private var isValid = true

    init(bundleIDs: [String]) throws {
        let description = CATapDescription()
        description.name = "Splitvox meeting tap"

        // Capture these applications, rather than everything except them.
        description.bundleIDs = bundleIDs
        description.isExclusive = false

        // Stereo mixdown of the captured applications.
        description.isMono = false
        description.isMixdown = true

        // The user must keep hearing the meeting while it is captured.
        description.muteBehavior = .unmuted

        // Visible only to this process.
        description.isPrivate = true

        // Chrome starts its audio helper lazily, only once sound actually
        // plays, so the process may not exist when recording begins. Without
        // this the tap would never pick that helper up.
        description.isProcessRestoreEnabled = true

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &createdTapID)
        guard status == noErr, createdTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw ProcessTapError.creationFailed(status)
        }

        self.tapID = createdTapID

        guard let resolvedUID = Self.stringProperty(kAudioTapPropertyUID, of: createdTapID) else {
            AudioHardwareDestroyProcessTap(createdTapID)
            throw ProcessTapError.uidUnavailable
        }
        self.uid = resolvedUID
    }

    /// Stream format the tap will deliver. Read after creation to size the
    /// recording files correctly.
    var streamDescription: AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    /// Destroy the tap. Safe to call more than once.
    ///
    /// Taps are system-wide objects that outlive a crashed client, so leaking
    /// one leaves an orphan visible in `kAudioHardwarePropertyTapList`.
    @discardableResult
    func invalidate() -> OSStatus {
        guard isValid else { return noErr }
        isValid = false
        return AudioHardwareDestroyProcessTap(tapID)
    }

    deinit {
        if isValid {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Tap objects currently registered system-wide. Used to confirm this class
    /// does not leak taps across create/destroy cycles.
    static func systemTapIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
