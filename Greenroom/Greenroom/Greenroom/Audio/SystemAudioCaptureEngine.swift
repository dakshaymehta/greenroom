import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures system audio from the primary display using ScreenCaptureKit.
///
/// macOS 14.2+ requires the Screen Recording permission to access system audio.
/// If the user later revokes that permission mid-session, `onStreamLost` fires
/// so the caller can update UI and prompt for re-authorization.
@MainActor
final class SystemAudioCaptureEngine: NSObject {

    // MARK: - Properties

    private var captureStream: SCStream?
    private var audioStreamOutput: GreenroomAudioStreamOutput?
    private var screenStreamOutput: GreenroomScreenStreamOutput?
    private let audioSampleQueue = DispatchQueue(
        label: "com.greenroom.systemaudio.capture",
        qos: .userInteractive
    )
    private let screenSampleQueue = DispatchQueue(
        label: "com.greenroom.systemaudio.screen-drain",
        qos: .utility
    )

    /// Called with each chunk of normalized PCM16 audio data from the system stream.
    var onAudioData: ((Data) -> Void)?

    /// Called when the capture stream stops unexpectedly — e.g. the user revokes
    /// Screen Recording permission while a session is already running.
    var onStreamLost: (() -> Void)?

    // MARK: - Start

    /// Discovers the primary display, configures an audio-only capture stream at
    /// 16 kHz mono PCM, and begins delivering sample buffers to `onAudioData`.
    ///
    /// Throws `AudioCaptureError.noDisplayFound` if ScreenCaptureKit cannot enumerate
    /// any displays, which is extremely rare but possible in headless or VM environments.
    func start() async throws {
        let audioDataHandler = onAudioData
        let pcm16AudioConverter = PCM16AudioConverter(targetSampleRate: 16_000)

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        guard let primaryDisplay = shareableContent.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        let streamConfiguration = SCStreamConfiguration()

        // Audio settings — 16 kHz mono matches AssemblyAI's recommended input format,
        // which avoids any resampling overhead on their end.
        streamConfiguration.capturesAudio = true
        streamConfiguration.sampleRate = 16000
        streamConfiguration.channelCount = 1

        // Display-bound SCStream instances still produce screen frames even when we're
        // only interested in system audio. Keep that video side tiny and low-frequency,
        // then attach a no-op screen output so ScreenCaptureKit stops spamming dropped
        // frame errors and wasting work on a full-resolution 60 fps stream.
        streamConfiguration.width = 16
        streamConfiguration.height = 16
        streamConfiguration.minimumFrameInterval = CMTime(seconds: 0.5, preferredTimescale: 600)
        streamConfiguration.queueDepth = 1
        streamConfiguration.showsCursor = false

        if #available(macOS 15.0, *) {
            streamConfiguration.captureMicrophone = false
        }

        // Exclude this process's own audio output so Greenroom's sound effects
        // (e.g. Fred's reaction sounds) don't feed back into the transcription pipeline.
        streamConfiguration.excludesCurrentProcessAudio = true

        let contentFilter = SCContentFilter(display: primaryDisplay, excludingWindows: [])

        let audioOutput = GreenroomAudioStreamOutput()
        audioOutput.onAudioSample = { sampleBuffer in
            guard let pcmData = AudioFormatConverter.convertCMSampleBufferToPCM16Data(
                sampleBuffer: sampleBuffer,
                converter: pcm16AudioConverter
            ) else {
                return
            }

            audioDataHandler?(pcmData)
        }
        self.audioStreamOutput = audioOutput

        let screenOutput = GreenroomScreenStreamOutput()
        self.screenStreamOutput = screenOutput

        let stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(
            audioOutput,
            type: .audio,
            sampleHandlerQueue: audioSampleQueue
        )
        try stream.addStreamOutput(
            screenOutput,
            type: .screen,
            sampleHandlerQueue: screenSampleQueue
        )

        try await stream.startCapture()
        self.captureStream = stream
    }

    // MARK: - Stop

    /// Stops the capture stream and releases all associated resources.
    func stop() async {
        try? await captureStream?.stopCapture()
        captureStream = nil
        audioStreamOutput = nil
        screenStreamOutput = nil
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCaptureEngine: SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The stream stopped for a reason outside our control — most likely the
        // Screen Recording permission was revoked. Notify the caller on the main actor.
        Task { @MainActor in
            self.onStreamLost?()
        }
    }
}

// MARK: - GreenroomAudioStreamOutput

/// Bridges SCStreamOutput callbacks into a simple closure-based API.
///
/// This private class exists solely to keep SCStreamOutput conformance isolated
/// from the @MainActor engine class — SCStreamOutput callbacks arrive on an
/// arbitrary background queue, not the main actor.
private final class GreenroomAudioStreamOutput: NSObject, SCStreamOutput {

    /// Receives each audio sample buffer as it arrives from the capture stream.
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // ScreenCaptureKit can deliver both video and audio outputs on the same stream.
        // We only registered for audio, but guard here as a belt-and-suspenders check.
        guard outputType == .audio else { return }
        onAudioSample?(sampleBuffer)
    }
}

/// Drains SCStream's required screen output so the framework doesn't log repeated
/// dropped-frame errors while we're using the stream purely for system audio.
private final class GreenroomScreenStreamOutput: NSObject, SCStreamOutput {

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, LocalizedError {

    case noDisplayFound
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display was found for system audio capture. This can occur in headless environments."
        case .permissionDenied:
            return "Screen Recording permission is required to capture system audio. Please grant access in System Settings > Privacy & Security."
        }
    }
}
