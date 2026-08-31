import CoreAudio
import Testing
@testable import Splitvox

@Suite("ヘッドセット状態")
struct AudioDeviceLookupTests {

    @Test("入力デバイスが無い場合はヘッドセットではない")
    func missingInputIsNotAHeadset() {
        let state = AudioDeviceLookup.headsetState(uid: nil, transport: nil)

        #expect(state == HeadsetState(external: false, physical: false))
    }

    @Test("内蔵マイクはヘッドセットではない")
    func builtInMicrophoneIsNotAHeadset() {
        let state = AudioDeviceLookup.headsetState(
            uid: AudioDeviceLookup.builtInMicrophoneUID,
            transport: kAudioDeviceTransportTypeBuiltIn
        )

        #expect(state == HeadsetState(external: false, physical: false))
    }

    @Test("接続種別不明の外部入力は物理ヘッドセットではない")
    func externalInputWithoutTransportIsNotPhysical() {
        let state = AudioDeviceLookup.headsetState(uid: "ExternalInput", transport: nil)

        #expect(state == HeadsetState(external: true, physical: false))
    }

    @Test("認識済みの物理入力は外部かつ物理ヘッドセットである")
    func recognizedPhysicalInputsAreExternalAndPhysical() {
        let physicalTransports: [UInt32] = [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeBuiltIn
        ]

        for transport in physicalTransports {
            let state = AudioDeviceLookup.headsetState(uid: "ExternalInput", transport: transport)

            #expect(state == HeadsetState(external: true, physical: true))
        }
    }

    @Test("未知の接続種別の外部入力は物理ヘッドセットではない")
    func unknownTransportIsNotPhysical() {
        let state = AudioDeviceLookup.headsetState(uid: "ExternalInput", transport: .max)

        #expect(state == HeadsetState(external: true, physical: false))
    }
}
