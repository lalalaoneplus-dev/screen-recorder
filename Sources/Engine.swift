import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264 (most compatible)" : "HEVC (smaller files)" }
    var avType: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

struct CaptureSpec {
    var display: SCDisplay
    var filter: SCContentFilter
    var sourceRect: CGRect?          // display-local points, top-left origin (area mode)
    var pixelSize: (w: Int, h: Int)
    var fps: Int
    var codec: VideoCodec
    var bitrate: Int
    var showsCursor: Bool
    var systemAudio: Bool
    var microphone: Bool
    var url: URL
}

enum RecorderError: LocalizedError {
    case noFrames, writerStart
    var errorDescription: String? {
        switch self {
        case .noFrames: return "No video frames were captured"
        case .writerStart: return "Couldn't create the video file"
        }
    }
}

/// Records one display (or one area of a display) to one .mov file.
/// Writes frames itself with AVAssetWriter so recordings can be paused and resumed:
/// while paused, frames are dropped, and on resume every later timestamp is shifted
/// back by the paused time so the file plays without a gap.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    let displayID: CGDirectDisplayID
    var onFailure: ((Error) -> Void)?

    private var stream: SCStream!
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "ScreenRecorder.capture", qos: .userInteractive)

    // Everything below is only touched on `queue`.
    private var started = false
    private var paused = false
    private var finishing = false
    private var failed = false
    private var pauseStart = CMTime.invalid
    private var offset = CMTime.zero
    private var lastVideo: CMSampleBuffer?
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioEnd = CMTime.invalid
    private var lastMicEnd = CMTime.invalid

    private static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    init(spec: CaptureSpec) throws {
        url = spec.url
        displayID = spec.display.displayID
        writer = try AVAssetWriter(outputURL: spec.url, fileType: .mov)
        // Write the file in 10-second fragments so a crash or power loss still leaves a playable video.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let codec = spec.codec
        let bitrate = spec.bitrate
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec.avType,
            AVVideoWidthKey: spec.pixelSize.w,
            AVVideoHeightKey: spec.pixelSize.h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: spec.fps,
                AVVideoMaxKeyFrameIntervalKey: spec.fps * 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        func audioIn() -> AVAssetWriterInput {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            i.expectsMediaDataInRealTime = true
            return i
        }
        audioInput = spec.systemAudio ? audioIn() : nil
        micInput = spec.microphone ? audioIn() : nil
        if let a = audioInput { writer.add(a) }
        if let m = micInput { writer.add(m) }

        super.init()

        let config = SCStreamConfiguration()
        config.width = spec.pixelSize.w
        config.height = spec.pixelSize.h
        if let r = spec.sourceRect { config.sourceRect = r }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(spec.fps))
        config.showsCursor = spec.showsCursor
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = spec.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = spec.microphone

        let s = SCStream(filter: spec.filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if spec.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if spec.microphone { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        stream = s

        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerStart }
    }

    func start() async throws {
        try await stream.startCapture()
    }

    /// Throw away a session that never started properly.
    func cancel() {
        queue.sync {
            finishing = true
            if writer.status == .writing { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func pause() {
        queue.sync {
            guard !paused else { return }
            paused = true
            pauseStart = Self.hostNow
        }
    }

    func resume() {
        queue.sync {
            guard paused else { return }
            offset = CMTimeAdd(offset, CMTimeSubtract(Self.hostNow, pauseStart))
            paused = false
        }
    }

    /// Stops capture and finalizes the file. Returns an error if the file couldn't be written.
    func finish() async -> Error? {
        try? await stream.stopCapture()
        return await withCheckedContinuation { (c: CheckedContinuation<Error?, Never>) in
            queue.async { [self] in
                finishing = true
                guard started, writer.status == .writing else {
                    let err = writer.error ?? (started ? nil : RecorderError.noFrames)
                    if writer.status == .writing { writer.cancelWriting() }
                    try? FileManager.default.removeItem(at: url)
                    c.resume(returning: err)
                    return
                }
                // A still screen produces no new frames, so repeat the last frame at the
                // stop time to make the video as long as the recording really was.
                let end = CMTimeSubtract(paused ? pauseStart : Self.hostNow, offset)
                if let last = lastVideo, lastVideoPTS.isValid,
                   CMTimeCompare(end, lastVideoPTS) > 0,
                   CMTimeGetSeconds(CMTimeSubtract(end, lastVideoPTS)) < 24 * 3600,
                   videoInput.isReadyForMoreMediaData,
                   let copy = stamped(last, at: end) {
                    videoInput.append(copy)
                }
                lastVideo = nil
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                micInput?.markAsFinished()
                writer.finishWriting {
                    c.resume(returning: self.writer.status == .completed ? nil : (self.writer.error ?? RecorderError.writerStart))
                }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sb), !paused, !finishing, !failed else { return }
        if writer.status == .failed { fail(writer.error); return }

        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  CMSampleBufferGetImageBuffer(sb) != nil else { return }
            let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sb), offset)
            if !started {
                writer.startSession(atSourceTime: pts)
                started = true
            }
            if lastVideoPTS.isValid && CMTimeCompare(pts, lastVideoPTS) <= 0 { return }
            guard videoInput.isReadyForMoreMediaData, let out = stamped(sb, at: pts) else { return }
            if videoInput.append(out) {
                lastVideoPTS = pts
                lastVideo = sb
            } else {
                fail(writer.error)
            }
        case .audio:
            appendAudio(sb, to: audioInput, lastEnd: &lastAudioEnd)
        case .microphone:
            appendAudio(sb, to: micInput, lastEnd: &lastMicEnd)
        @unknown default:
            break
        }
    }

    private func appendAudio(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?, lastEnd: inout CMTime) {
        guard started, let input else { return }
        let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sb), offset)
        // Drop audio that overlaps what's already written (happens right after a resume).
        if lastEnd.isValid && CMTimeCompare(pts, CMTimeSubtract(lastEnd, CMTime(value: 1, timescale: 1000))) < 0 { return }
        guard input.isReadyForMoreMediaData, let out = shifted(sb, by: offset) else { return }
        if input.append(out) {
            lastEnd = CMTimeAdd(pts, CMSampleBufferGetDuration(sb))
        } else {
            fail(writer.error)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard !finishing else { return }
            fail(error)
        }
    }

    private func fail(_ error: Error?) {
        guard !failed else { return }
        failed = true
        let err = error ?? RecorderError.writerStart
        onFailure?(err)
    }

    // MARK: Timing helpers

    private func stamped(_ sb: CMSampleBuffer, at pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                                    sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                    sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    private func shifted(_ sb: CMSampleBuffer, by off: CMTime) -> CMSampleBuffer? {
        if CMTimeCompare(off, .zero) == 0 { return sb }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else { return nil }
        for i in 0..<count {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, off)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, off)
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                                    sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                                    sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}
