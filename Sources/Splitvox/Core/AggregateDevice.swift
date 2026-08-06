import CoreAudio
import Foundation

enum AggregateDeviceError: LocalizedError {
    case creationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let status):
            return "録音用の集約デバイスを作成できませんでした (OSStatus \(status))"
        }
    }
}

/// A private aggregate device holding the meeting tap and the microphone.
///
/// This is the mechanism that makes the two recordings line up. Both endpoints
/// belong to one aggregate device, so Core Audio drives them from a single
/// clock; capturing them as two independent devices would let them drift apart
/// over a long meeting and misalign the merged transcript.
final class AggregateDevice {

    let deviceID: AudioObjectID
    let uid: String

    private var isValid = true

    init(tapUID: String, inputDeviceUID: String) throws {
        let generatedUID = "io.github.tori-create-7991.splitvox.aggregate.\(UUID().uuidString)"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Splitvox Capture",
            kAudioAggregateDeviceUIDKey: generatedUID,

            // Visible only to this process; it must not appear in Sound
            // Settings or become selectable by other applications.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,

            // The microphone drives the clock. It is real hardware, whereas the
            // tap is synthesised from whatever the meeting app happens to play.
            kAudioAggregateDeviceMainSubDeviceKey: inputDeviceUID,

            // Off deliberately. With auto-start on, the whole aggregate device
            // stalls while the tapped applications are silent — and because the
            // microphone shares this device, the local voice stops recording
            // too. Measured: with nothing playing, both tracks came out at
            // -inf; with a video running, both recorded normally.
            //
            // That would lose the opening of every meeting, where you speak
            // before the other side does.
            kAudioAggregateDeviceTapAutoStartKey: false,

            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: inputDeviceUID,
                    kAudioSubDeviceDriftCompensationKey: true
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var createdID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdID)
        guard status == noErr, createdID != AudioObjectID(kAudioObjectUnknown) else {
            throw AggregateDeviceError.creationFailed(status)
        }

        self.deviceID = createdID
        self.uid = generatedUID
    }

    var inputChannelCount: Int {
        AudioDeviceLookup.inputChannelCount(of: deviceID)
    }

    /// Per-stream input channel counts, in stream order.
    ///
    /// Which stream is the tap and which is the microphone is not documented,
    /// so `--probe-aggregate` reports this and the recorder derives the split
    /// from measured values rather than an assumption.
    var inputStreamChannelCounts: [Int] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else {
            return []
        }

        let listPointer = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return listPointer.map { Int($0.mNumberChannels) }
    }

    var nominalSampleRate: Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    @discardableResult
    func invalidate() -> OSStatus {
        guard isValid else { return noErr }
        isValid = false
        return AudioHardwareDestroyAggregateDevice(deviceID)
    }

    deinit {
        if isValid {
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
    }
}
