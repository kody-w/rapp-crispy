import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit

public struct ScreenCaptureChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let detail: String
}

private final class ScreenVideoWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "io.rapp.crispy.screen-writer")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let failure: @Sendable (String) -> Void
    private var started = false
    private var finished = false
    private var appendError: String?

    init(url: URL, width: Int, height: Int, failure: @escaping @Sendable (String) -> Void) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = true
        self.failure = failure
        super.init()
        guard writer.canAdd(input) else { throw CrispyError.unavailable("H.264 screen video cannot be written on this system.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CrispyError.unavailable("Could not start the screen video writer.") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, !finished, appendError == nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        if !started {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        guard input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            let message = writer.error?.localizedDescription ?? "The screen writer rejected a video frame."
            appendError = message
            failure(message)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failure("Screen sharing stopped: \(error.localizedDescription)")
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.finished else {
                    continuation.resume(throwing: CrispyError.unavailable("The screen writer has already stopped."))
                    return
                }
                self.finished = true
                guard self.started, self.appendError == nil else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: CrispyError.invalidRecording(self.appendError ?? "no complete screen frames arrived"))
                    return
                }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: self.writer.error ?? CrispyError.invalidRecording("screen video finalization failed")) }
                }
            }
        }
    }

    func abort() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finished = true
                self.writer.cancelWriting()
                continuation.resume()
            }
        }
    }
}

@MainActor
public final class ScreenCaptureService: ObservableObject {
    @Published public private(set) var choices: [ScreenCaptureChoice] = []
    @Published public private(set) var isLoading = false
    public var onFailure: (String) -> Void = { _ in }
    private var content: SCShareableContent?
    private var stream: SCStream?
    private var sink: ScreenVideoWriter?
    private var captureToken: UUID?

    public init() {}

    public func loadChoices() async throws {
        isLoading = true
        defer { isLoading = false }
        // This is called only by the user's Choose screen/window button, never during launch.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        self.content = content
        choices = content.displays.enumerated().map { index, display in
            ScreenCaptureChoice(id: "display-\(display.displayID)", label: "Display \(index + 1)",
                                detail: "\(display.width) × \(display.height) — all visible content")
        } + content.windows.filter { $0.frame.width >= 80 && $0.frame.height >= 80 }.map {
            ScreenCaptureChoice(id: "window-\($0.windowID)", label: $0.title?.isEmpty == false ? $0.title! : "Untitled window",
                                detail: $0.owningApplication?.applicationName ?? "Window")
        }
    }

    public func label(for selection: String?) -> String? {
        choices.first { $0.id == selection }?.label
    }

    func start(selection: String, directory: URL) async throws {
        guard stream == nil, let content, choices.contains(where: { $0.id == selection }) else {
            throw CrispyError.unavailable("Explicitly choose a display or window before recording screen video.")
        }
        let filter: SCContentFilter
        let sourceWidth: Double
        let sourceHeight: Double
        if let display = content.displays.first(where: { "display-\($0.displayID)" == selection }) {
            filter = SCContentFilter(display: display, excludingWindows: [])
            sourceWidth = Double(display.width)
            sourceHeight = Double(display.height)
        } else if let window = content.windows.first(where: { "window-\($0.windowID)" == selection }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceWidth = window.frame.width * 2
            sourceHeight = window.frame.height * 2
        } else {
            throw CrispyError.unavailable("The chosen screen/window is no longer available. Choose it again.")
        }
        let scale = min(1, 1920 / max(sourceWidth, sourceHeight))
        let width = max(2, Int(sourceWidth * scale) / 2 * 2)
        let height = max(2, Int(sourceHeight * scale) / 2 * 2)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let token = UUID()
        captureToken = token
        let writer = try ScreenVideoWriter(url: directory.appendingPathComponent("screen.mov"), width: width, height: height) { [weak self] error in
            Task { @MainActor in
                guard let self, self.captureToken == token else { return }
                self.onFailure(error)
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: writer)
        do {
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            try Task.checkCancellation()
            try await stream.startCapture()
            self.stream = stream
            sink = writer
        } catch {
            captureToken = nil
            await writer.abort()
            throw error
        }
    }

    func stop() async throws -> String? {
        guard let stream, let sink else { return nil }
        captureToken = nil
        self.stream = nil
        self.sink = nil
        do {
            try await stream.stopCapture()
            try await sink.finish()
            return "screen.mov"
        } catch {
            await sink.abort()
            throw error
        }
    }
}
