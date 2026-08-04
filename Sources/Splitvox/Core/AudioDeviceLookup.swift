import CoreAudio
import Foundation

struct AudioInputDevice: Equatable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let inputChannelCount: Int
}

/// Resolves input devices, which the aggregate device needs by UID.
///
/// The device is user-selectable because a virtual microphone may sit between
/// the hardware and the app — Krisp registers one on this machine. Routing
/// through it yields noise-suppressed audio but couples recording to that
/// process staying alive, so neither choice is right for everyone.
enum AudioDeviceLookup {

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultInputDeviceID() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    static func uid(of device: AudioObjectID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: device)
    }

    static func name(of device: AudioObjectID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: device)
    }

    /// Number of input channels, summed across the device's input streams.
    /// Zero means the device is output-only and cannot back a microphone track.
    static func inputChannelCount(of device: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let listPointer = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return listPointer.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func inputDevice(for objectID: AudioObjectID) -> AudioInputDevice? {
        guard let uid = uid(of: objectID) else { return nil }
        return AudioInputDevice(
            objectID: objectID,
            uid: uid,
            name: name(of: objectID) ?? uid,
            inputChannelCount: inputChannelCount(of: objectID)
        )
    }

    static func availableInputDevices() -> [AudioInputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids
            .compactMap(inputDevice(for:))
            .filter { $0.inputChannelCount > 0 }
    }

    /// UID of the Mac's own microphone. Anything else selected as the default
    /// input means an external mic — a headset, earbuds, or a virtual device.
    static let builtInMicrophoneUID = "BuiltInMicrophoneDevice"

    /// Whether the default input is something other than the built-in mic.
    ///
    /// Used as the signal that a call is about to happen: putting on a headset
    /// is a deliberate act that precedes a meeting, and unlike watching for
    /// microphone use it does not depend on which application is running.
    static func isExternalInputActive() -> Bool {
        guard let device = defaultInputDeviceID(), let uid = uid(of: device) else { return false }
        return uid != builtInMicrophoneUID
    }

    /// Name of the current default input, for showing in diagnostics.
    static func defaultInputName() -> String? {
        defaultInputDeviceID().flatMap(name(of:))
    }

    /// The device to record the local speaker from: the user's choice when it
    /// is still present, otherwise the system default.
    static func resolveInputDevice(preferredUID: String?) -> AudioInputDevice? {
        if let preferredUID,
           let match = availableInputDevices().first(where: { $0.uid == preferredUID }) {
            return match
        }
        return defaultInputDeviceID().flatMap(inputDevice(for:))
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID
    ) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
