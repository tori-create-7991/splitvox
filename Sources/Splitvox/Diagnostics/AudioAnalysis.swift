import AVFAudio
import Foundation

/// Measurement helpers for verifying that the two files really did capture
/// different people — the property the whole design rests on.
enum AudioAnalysis {

    struct Report {
        let duration: TimeInterval
        let channelCount: Int
        let sampleRate: Double
        let overallRMS: Float
        let perSecondRMS: [Float]

        var peakRMS: Float { perSecondRMS.max() ?? 0 }
    }

    static func analyse(_ url: URL) throws -> Report {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let framesPerSecond = AVAudioFrameCount(sampleRate)

        var perSecond: [Float] = []
        var totalSquares: Double = 0
        var totalSamples: Int = 0

        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let toRead = min(framesPerSecond, remaining)
            guard toRead > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { break }

            try file.read(into: buffer, frameCount: toRead)
            guard let channels = buffer.floatChannelData else { break }

            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }

            var windowSquares: Double = 0
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frames {
                    let value = Double(samples[frame])
                    windowSquares += value * value
                }
            }

            let windowSamples = frames * Int(format.channelCount)
            perSecond.append(Float((windowSquares / Double(windowSamples)).squareRoot()))
            totalSquares += windowSquares
            totalSamples += windowSamples
        }

        let overall = totalSamples > 0
            ? Float((totalSquares / Double(totalSamples)).squareRoot())
            : 0

        return Report(
            duration: Double(file.length) / sampleRate,
            channelCount: Int(format.channelCount),
            sampleRate: sampleRate,
            overallRMS: overall,
            perSecondRMS: perSecond
        )
    }

    /// Decibels relative to full scale. Easier to read than a raw RMS when the
    /// question is "is there anything here at all".
    static func decibels(_ rms: Float) -> Float {
        rms > 0 ? 20 * log10(rms) : -.infinity
    }
}
