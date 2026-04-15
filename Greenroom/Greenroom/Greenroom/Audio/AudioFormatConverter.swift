import AVFoundation
import CoreMedia

/// Utility functions for converting audio buffers into raw PCM 16-bit signed integer data.
///
/// AssemblyAI's streaming WebSocket API expects raw PCM s16le (16-bit signed little-endian)
/// audio bytes. Both capture paths — ScreenCaptureKit CMSampleBuffers and AVAudioEngine
/// AVAudioPCMBuffers — produce different buffer types, so we need two conversion paths.
enum AudioFormatConverter {

    // MARK: - CMSampleBuffer Path (System Audio via ScreenCaptureKit)

    /// Extracts the raw PCM bytes from a CMSampleBuffer produced by ScreenCaptureKit.
    ///
    /// ScreenCaptureKit already delivers audio as PCM s16le when configured with
    /// `sampleRate=16000` and `channelCount=1`, so no sample-by-sample conversion
    /// is needed — we just copy the raw bytes out of the block buffer.
    ///
    /// Returns `nil` if the sample buffer contains no valid data block, which can
    /// happen briefly at stream startup before the first real audio frames arrive.
    static func convertCMSampleBufferToPCM16Data(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var dataPointer: UnsafeMutablePointer<CChar>?
        var blockBufferLength: Int = 0

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &blockBufferLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            return nil
        }

        return Data(bytes: pointer, count: blockBufferLength)
    }

    // MARK: - AVAudioPCMBuffer Path (Microphone via AVAudioEngine)

    /// Converts an AVAudioPCMBuffer of Float32 samples into raw PCM s16le bytes.
    ///
    /// AVAudioEngine taps produce non-interleaved Float32 samples in the range [-1.0, 1.0].
    /// AssemblyAI expects Int16 samples, so we clamp each float to that range and scale
    /// by Int16.max (32767) before writing as little-endian Int16 pairs.
    ///
    /// Returns `nil` if the buffer contains no float channel data, which should not
    /// happen in normal operation but is possible if the engine is misconfigured.
    static func convertAVAudioPCMBufferToPCM16Data(pcmBuffer: AVAudioPCMBuffer) -> Data? {
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            return nil
        }

        let frameCount = Int(pcmBuffer.frameLength)
        let channelZeroSamples = floatChannelData[0]

        var outputData = Data(capacity: frameCount * MemoryLayout<Int16>.size)

        for frameIndex in 0..<frameCount {
            // Clamp before scaling to prevent integer overflow on occasional hot samples
            // that slightly exceed the normalized [-1, 1] range due to floating-point precision.
            let clampedSample = max(-1.0, min(1.0, channelZeroSamples[frameIndex]))
            let scaledSample = Int16(clampedSample * Float(Int16.max))

            withUnsafeBytes(of: scaledSample) { outputData.append(contentsOf: $0) }
        }

        return outputData
    }
}
