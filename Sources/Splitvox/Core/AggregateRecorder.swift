import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

enum AggregateRecorderError: LocalizedError {
    case noInputDevice
    case unexpectedChannelLayout([Int])
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case fileCreationFailed(URL, underlying: Error)
    case unsupportedSampleFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "録音に使える入力デバイスが見つかりませんでした"
        case .unexpectedChannelLayout(let counts):
            return "集約デバイスのチャンネル構成が想定と異なります (\(counts))。"
                + " --probe-aggregate で構成を確認してください"
        case .ioProcCreationFailed(let status):
            return "録音コールバックを作成できませんでした (OSStatus \(status))"
        case .deviceStartFailed(let status):
            return "録音を開始できませんでした (OSStatus \(status))。"
                + " マイクとシステム音声録音の許可を確認してください"
        case .fileCreationFailed(let url, let underlying):
            return "録音ファイルを作成できませんでした: \(url.lastPathComponent)"
                + " (\(underlying.localizedDescription))"
        case .unsupportedSampleFormat:
            return "集約デバイスのサンプル形式に対応していません (32bit float 以外)"
        }
    }
}

/// Records the meeting into two separate files that share one clock.
///
/// `me.wav` comes from the microphone sub-device and `them.wav` from the
/// process tap. Keeping them apart at capture time is what makes speaker
/// attribution exact instead of a guess.
///
/// Reads the aggregate device through an `AudioDeviceIOProc` rather than
/// `AVAudioEngine`. The engine normalises its input to the format it decided
/// on: with a 3-channel aggregate device it reported `AUHAL bus1 input 3 ch`
/// but `AUHAL bus1 output 1 ch` and delivered a mono downmix, which destroys
/// the very separation this class exists to preserve.
final class AggregateRecorder {

    let inputDeviceName: String
    let layout: CaptureChannelLayout

    private let tap: ProcessTap
    private let device: AggregateDevice

    private var procID: AudioDeviceIOProcID?
    private var microphoneFile: AVAudioFile?
    private var systemAudioFile: AVAudioFile?
    private var isRunning = false

    /// The IO block runs here, so file writes are already serialised and off
    /// the real-time thread.
    private let ioQueue = DispatchQueue(label: "com.ryo.splitvox.recorder.io")

    /// Set once from the first callback, for `--probe-record` to report the
    /// buffer layout the device actually delivers.
    private(set) var observedBufferLayout: [Int] = []

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

        let sampleRate = device.nominalSampleRate

        microphoneFile = try Self.makeFile(
            at: microphoneURL,
            sampleRate: sampleRate,
            channels: layout.microphoneChannels.count
        )
        systemAudioFile = try Self.makeFile(
            at: systemAudioURL,
            sampleRate: sampleRate,
            channels: layout.systemAudioChannels.count
        )

        var createdProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdProcID,
            device.deviceID,
            ioQueue
        ) { [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }

        guard createStatus == noErr, let createdProcID else {
            microphoneFile = nil
            systemAudioFile = nil
            throw AggregateRecorderError.ioProcCreationFailed(createStatus)
        }
        procID = createdProcID

        let startStatus = AudioDeviceStart(device.deviceID, createdProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device.deviceID, createdProcID)
            procID = nil
            microphoneFile = nil
            systemAudioFile = nil
            throw AggregateRecorderError.deviceStartFailed(startStatus)
        }

        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let procID {
            AudioDeviceStop(device.deviceID, procID)
            AudioDeviceDestroyIOProcID(device.deviceID, procID)
            self.procID = nil
        }

        // Close the files only once every queued callback has finished,
        // otherwise the tail of the recording is lost.
        ioQueue.sync {
            microphoneFile = nil
            systemAudioFile = nil
        }

        device.invalidate()
        tap.invalidate()
    }

    /// Split one device callback into the two files.
    ///
    /// The aggregate device presents its sub-device and its tap as separate
    /// buffers, and a buffer may itself hold several interleaved channels. The
    /// two are flattened into one global channel index so `CaptureChannelLayout`
    /// — which is expressed in device channel numbers — can address them.
    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )

        if observedBufferLayout.isEmpty {
            observedBufferLayout = buffers.map { Int($0.mNumberChannels) }
        }

        if let file = microphoneFile {
            write(buffers, channels: layout.microphoneChannels, to: file)
        }
        if let file = systemAudioFile {
            write(buffers, channels: layout.systemAudioChannels, to: file)
        }
    }

    private func write(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        channels: Range<Int>,
        to file: AVAudioFile
    ) {
        let frameCount = Self.frameCount(of: buffers)
        guard frameCount > 0 else { return }

        guard let out = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let destination = out.floatChannelData else { return }

        out.frameLength = AVAudioFrameCount(frameCount)

        for (outputIndex, globalChannel) in channels.enumerated() {
            copyChannel(globalChannel, from: buffers, frameCount: frameCount, to: destination[outputIndex])
        }

        try? file.write(from: out)
    }

    /// Copy one device channel, addressed by its global index across all
    /// buffers, into a contiguous destination.
    private func copyChannel(
        _ globalChannel: Int,
        from buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        to destination: UnsafeMutablePointer<Float>
    ) {
        var channelBase = 0

        for buffer in buffers {
            let channelsInBuffer = Int(buffer.mNumberChannels)
            defer { channelBase += channelsInBuffer }

            guard globalChannel >= channelBase,
                  globalChannel < channelBase + channelsInBuffer,
                  let raw = buffer.mData else { continue }

            let localChannel = globalChannel - channelBase
            let samples = raw.assumingMemoryBound(to: Float.self)
            let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelsInBuffer
            let frames = min(frameCount, available)

            for frame in 0..<frames {
                destination[frame] = samples[frame * channelsInBuffer + localChannel]
            }
            if frames < frameCount {
                for frame in frames..<frameCount { destination[frame] = 0 }
            }
            return
        }

        // Channel not present in this callback: emit silence rather than
        // leaving the destination uninitialised.
        for frame in 0..<frameCount { destination[frame] = 0 }
    }

    private static func frameCount(of buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        buffers.reduce(0) { longest, buffer in
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            return max(longest, frames)
        }
    }

    private static func makeFile(at url: URL, sampleRate: Double, channels: Int) throws -> AVAudioFile {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else {
            throw AggregateRecorderError.unsupportedSampleFormat
        }

        do {
            return try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AggregateRecorderError.fileCreationFailed(url, underlying: error)
        }
    }

    deinit {
        if let procID {
            AudioDeviceStop(device.deviceID, procID)
            AudioDeviceDestroyIOProcID(device.deviceID, procID)
        }
        device.invalidate()
        tap.invalidate()
    }
}
