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
    private let ioQueue = DispatchQueue(label: "io.github.tori-create-7991.splitvox.recorder.io")

    /// Set once from the first callback, for `--probe-record` to report the
    /// buffer layout the device actually delivers.
    private(set) var observedBufferLayout: [Int] = []

    /// Surfaced rather than swallowed: a file that silently fails to write
    /// leaves a zero-length recording that looks like silence.
    private(set) var writeFailures = 0
    private(set) var firstWriteError: String?

    /// Callbacks seen, and how many of those carried any non-zero sample on the
    /// tap channels.
    ///
    /// Separates "the tap delivered nothing" from "the tap delivered silence",
    /// which look identical in the resulting file but have different causes.
    private(set) var callbackCount = 0
    private(set) var tapNonSilentCallbacks = 0

    /// Diagnostics from the tap, surfaced for the session log.
    var resolvedProcessCount: Int { tap.resolvedProcessCount }
    var tapStreamDescription: AudioStreamBasicDescription? { tap.streamDescription }

    /// Live taps on each side's audio, for transcribing while recording.
    ///
    /// Separate from the files rather than replacing them: if transcription
    /// fails or the model stalls, the audio is still on disk and the session
    /// can be transcribed again afterwards.
    var onMicrophoneBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Formats the live buffers will be delivered in.
    ///
    /// Derived from the device rather than read back from the open files, so a
    /// transcriber can be started *before* recording begins. Starting it after
    /// would drop the first seconds of the meeting.
    var microphoneFormat: AVAudioFormat? {
        AVAudioFormat(
            standardFormatWithSampleRate: device.nominalSampleRate,
            channels: AVAudioChannelCount(layout.microphoneChannels.count)
        )
    }

    var systemAudioFormat: AVAudioFormat? {
        AVAudioFormat(
            standardFormatWithSampleRate: device.nominalSampleRate,
            channels: AVAudioChannelCount(layout.systemAudioChannels.count)
        )
    }

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

        callbackCount += 1
        if containsAudio(buffers, channels: layout.systemAudioChannels) {
            tapNonSilentCallbacks += 1
        }

        if let file = microphoneFile {
            write(buffers, channels: layout.microphoneChannels, to: file, live: onMicrophoneBuffer)
        }
        if let file = systemAudioFile {
            write(buffers, channels: layout.systemAudioChannels, to: file, live: onSystemAudioBuffer)
        }
    }

    /// Whether any sample on the given device channels is non-zero.
    ///
    /// Checks the raw callback rather than the written file, so a tap that
    /// delivers digital silence can be told apart from one that delivers
    /// nothing at all.
    private func containsAudio(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        channels: Range<Int>
    ) -> Bool {
        var channelBase = 0

        for buffer in buffers {
            let channelsInBuffer = Int(buffer.mNumberChannels)
            defer { channelBase += channelsInBuffer }

            guard let raw = buffer.mData else { continue }
            let overlap = max(channelBase, channels.lowerBound)
                ..< min(channelBase + channelsInBuffer, channels.upperBound)
            guard !overlap.isEmpty else { continue }

            let samples = raw.assumingMemoryBound(to: Float.self)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelsInBuffer

            for frame in 0..<frames {
                for channel in overlap where samples[frame * channelsInBuffer + (channel - channelBase)] != 0 {
                    return true
                }
            }
        }

        return false
    }

    private func write(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        channels: Range<Int>,
        to file: AVAudioFile,
        live: ((AVAudioPCMBuffer) -> Void)?
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

        // Write to disk first: the file is the durable record, and a slow or
        // failing transcriber must not be able to cost us the audio.
        do {
            try file.write(from: out)
        } catch {
            if firstWriteError == nil {
                firstWriteError = error.localizedDescription
            }
            writeFailures += 1
        }
        live?(out)
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

    /// Create the on-disk recording as 16-bit PCM.
    ///
    /// 32-bit float costs about 2 GB per hour across both tracks, which does
    /// not survive routine use; 16-bit halves that with no audible loss for
    /// speech. AAC would be far smaller still, but `AVAudioFile` accepted the
    /// writes and then produced zero-length files — the encoder never flushed —
    /// so it is not trustworthy here.
    ///
    /// `commonFormat: .pcmFormatFloat32` still describes the buffers handed to
    /// `write(from:)`; AVAudioFile converts them to 16-bit on the way to disk.
    private static func makeFile(at url: URL, sampleRate: Double, channels: Int) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
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
