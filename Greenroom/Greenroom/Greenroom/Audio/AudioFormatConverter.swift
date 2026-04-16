import AVFoundation
import CoreMedia

/// Converts arbitrary live audio buffers into the single format Greenroom streams:
/// 16 kHz, mono, PCM signed 16-bit little-endian.
final class PCM16AudioConverter {

    private let targetAudioFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?

    init(targetSampleRate: Double = 16_000) {
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        // Reuse the existing converter whenever the input format's shape hasn't
        // actually changed. Comparing on the concrete format properties avoids
        // allocating a fresh `settings.description` string on every audio buffer,
        // which at ~20-50 Hz of mic callbacks was measurable overhead.
        if !matchesCachedInputFormat(audioBuffer.format) {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
            cachedInputFormat = audioBuffer.format
        }

        guard let audioConverter else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return audioBuffer
        }

        guard conversionStatus != .error else { return nil }
        guard let dataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else { return nil }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else { return nil }

        return Data(bytes: dataPointer, count: byteCount)
    }

    private func matchesCachedInputFormat(_ incomingFormat: AVAudioFormat) -> Bool {
        guard let cachedInputFormat else { return false }
        return cachedInputFormat.sampleRate == incomingFormat.sampleRate
            && cachedInputFormat.channelCount == incomingFormat.channelCount
            && cachedInputFormat.commonFormat == incomingFormat.commonFormat
            && cachedInputFormat.isInterleaved == incomingFormat.isInterleaved
    }
}

enum AudioFormatConverter {

    static func convertCMSampleBufferToPCM16Data(
        sampleBuffer: CMSampleBuffer,
        converter: PCM16AudioConverter
    ) -> Data? {
        guard let pcmBuffer = makeAVAudioPCMBuffer(from: sampleBuffer) else {
            return nil
        }

        return converter.convertToPCM16Data(from: pcmBuffer)
    }

    private static func makeAVAudioPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        return try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}
