import AVFAudio
import CoreAudio
import Foundation

enum AggregateRecorderError: LocalizedError {
    case noInputDevice
    case unexpectedChannelLayout([Int])
    case audioUnitUnavailable
    case deviceAssignmentFailed(OSStatus)
    case unexpectedInputFormat(channels: Int, expected: Int)
    case interleavedInputUnsupported

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "録音に使える入力デバイスが見つかりませんでした"
        case .unexpectedChannelLayout(let counts):
            return "集約デバイスのチャンネル構成が想定と異なります (\(counts))。"
                + " --probe-aggregate で構成を確認してください"
        case .audioUnitUnavailable:
            return "オーディオ入力ユニットを取得できませんでした"
        case .deviceAssignmentFailed(let status):
            return "録音デバイスの割り当てに失敗しました (OSStatus \(status))"
        case .unexpectedInputFormat(let channels, let expected):
            return "入力チャンネル数が想定と異なります (実際 \(channels) / 想定 \(expected))"
        case .interleavedInputUnsupported:
            return "インターリーブ形式の入力には対応していません"
        }
    }
}

/// Records the meeting into two separate files that share one clock.
///
/// `me.wav` comes from the microphone sub-device and `them.wav` from the
/// process tap. Keeping them apart at capture time is what makes speaker
/// attribution exact instead of a guess.
final class AggregateRecorder {

    let inputDeviceName: String
    let layout: CaptureChannelLayout

    private let tap: ProcessTap
    private let device: AggregateDevice
    private let engine = AVAudioEngine()

    private var microphoneFile: AVAudioFile?
    private var systemAudioFile: AVAudioFile?
    private var isRunning = false

    /// Serialises file writes against `stop()`, which runs on the main thread
    /// while the tap callback runs on a render thread.
    private let writeQueue = DispatchQueue(label: "com.ryo.splitvox.recorder.write")

    init(bundleIDs: [String], preferredInputUID: String?) throws {
        guard let input = AudioDeviceLookup.resolveInputDevice(preferredUID: preferredInputUID) else {
            throw AggregateRecorderError.noInputDevice
        }
        inputDeviceName = input.name

        let createdTap = try ProcessTap(bundleIDs: bundleIDs)

        let createdDevice: AggregateDevice
        do {
            createdDevice = try AggregateDevice(tapUID: createdTap.uid, inputDeviceUID: input.uid)
        } catch {
            createdTap.invalidate()
            throw error
        }

        let counts = createdDevice.inputStreamChannelCounts
        guard let resolvedLayout = CaptureChannelLayout.resolve(streamChannelCounts: counts) else {
            createdDevice.invalidate()
            createdTap.invalidate()
            throw AggregateRecorderError.unexpectedChannelLayout(counts)
        }

        self.tap = createdTap
        self.device = createdDevice
        self.layout = resolvedLayout
    }

    func start(microphoneURL: URL, systemAudioURL: URL) throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode

        // Point the engine at the aggregate device before reading its format:
        // the input node otherwise reports the system default device's layout.
        guard let audioUnit = inputNode.audioUnit else {
            throw AggregateRecorderError.audioUnitUnavailable
        }
        var deviceID = device.deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AggregateRecorderError.deviceAssignmentFailed(status)
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard !inputFormat.isInterleaved else {
            throw AggregateRecorderError.interleavedInputUnsupported
        }
        guard Int(inputFormat.channelCount) == layout.totalChannels else {
            throw AggregateRecorderError.unexpectedInputFormat(
                channels: Int(inputFormat.channelCount),
                expected: layout.totalChannels
            )
        }

        microphoneFile = try Self.makeFile(
            at: microphoneURL,
            sampleRate: inputFormat.sampleRate,
            channels: layout.microphoneChannels.count
        )
        systemAudioFile = try Self.makeFile(
            at: systemAudioURL,
            sampleRate: inputFormat.sampleRate,
            channels: layout.systemAudioChannels.count
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.writeQueue.async { self?.write(buffer) }
        }

        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Close the files only after every queued buffer has been written,
        // otherwise the tail of the recording is lost.
        writeQueue.sync {
            microphoneFile = nil
            systemAudioFile = nil
        }

        device.invalidate()
        tap.invalidate()
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let source = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        if let file = microphoneFile {
            writeSlice(from: source, frameCount: frameCount, channels: layout.microphoneChannels, to: file)
        }
        if let file = systemAudioFile {
            writeSlice(from: source, frameCount: frameCount, channels: layout.systemAudioChannels, to: file)
        }
    }

    private func writeSlice(
        from source: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channels: Range<Int>,
        to file: AVAudioFile
    ) {
        guard let out = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let destination = out.floatChannelData else { return }

        out.frameLength = AVAudioFrameCount(frameCount)
        for (offset, channel) in channels.enumerated() {
            destination[offset].update(from: source[channel], count: frameCount)
        }

        try? file.write(from: out)
    }

    private static func makeFile(at url: URL, sampleRate: Double, channels: Int) throws -> AVAudioFile {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else {
            throw AggregateRecorderError.unexpectedInputFormat(channels: channels, expected: channels)
        }

        return try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    deinit {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        device.invalidate()
        tap.invalidate()
    }
}
