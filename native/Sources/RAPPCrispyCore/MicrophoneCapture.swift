import AVFoundation
import AudioToolbox
import Foundation

private final class AudioCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failure: Error?
    private var lastMeterTime: Double = 0
    private let meter: @Sendable (Double) -> Void
    private let failed: @Sendable (String) -> Void

    init(file: AVAudioFile, meter: @escaping @Sendable (Double) -> Void,
         failed: @escaping @Sendable (String) -> Void) {
        self.file = file
        self.meter = meter
        self.failed = failed
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let file, failure == nil else { lock.unlock(); return }
        var errorMessage: String?
        do { try file.write(from: buffer) }
        catch { failure = error; errorMessage = error.localizedDescription }
        let now = ProcessInfo.processInfo.systemUptime
        var level: Double?
        if now - lastMeterTime > 0.1, let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 0 {
            var sum = 0.0
            for index in 0..<Int(buffer.frameLength) { sum += Double(channel[index]) * Double(channel[index]) }
            level = min(1, sqrt(sum / Double(buffer.frameLength)))
            lastMeterTime = now
        }
        lock.unlock()
        if let level { meter(level) }
        if let errorMessage { failed("Microphone audio could not be written: \(errorMessage)") }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        if let failure { throw failure }
    }
}

@MainActor
final class MicrophoneCapture {
    var onMeter: (Double) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    private var engine: AVAudioEngine?
    private var sink: AudioCaptureSink?
    private var directory: URL?
    private var mode: EnhancementEngine = .none
    private var observer: NSObjectProtocol?
    private var captureToken: UUID?

    func start(in directory: URL, settings: CaptureSettings) async throws -> RecordingDetails {
        guard engine == nil else { throw CrispyError.busy }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        try Task.checkCancellation()
        guard allowed else {
            throw CrispyError.unavailable("Microphone permission was not granted to RAPP Crispy. Enable it in System Settings → Privacy & Security → Microphone; no recording has started.")
        }
        let devices = try AudioDevices.list()
        let device = settings.deviceID.flatMap { selected in devices.first { $0.id == selected && $0.inputChannels > 0 } }
            ?? (settings.deviceID == nil ? DeviceDiagnostics.preferredInput(devices) : nil)
        guard let device else { throw CrispyError.unavailable("The selected microphone is unavailable. Choose an input in the app; a virtual device is never selected automatically.") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if settings.engine == .appleVoiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) }
            catch { throw CrispyError.unavailable("Apple voice processing could not be enabled on this device: \(error.localizedDescription). Choose another device or explicitly select Original microphone; no substitute engine was used.") }
            guard input.isVoiceProcessingEnabled else { throw CrispyError.unavailable("AVFoundation did not enable voice processing. Capture was not started.") }
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingAGCEnabled = false
        }
        guard let unit = input.audioUnit else { throw CrispyError.unavailable("The microphone has no AVFoundation audio unit.") }
        var identifier = AudioDeviceID(device.id)
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                         &identifier, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw CrispyError.unavailable("Could not select \(device.name) (OSStatus \(result)). No fallback microphone was used.") }
        var actual = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let query = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size)
        guard query == noErr, actual == identifier else {
            throw CrispyError.unavailable("AVFoundation did not retain the selected microphone. Capture was not started.")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CrispyError.invalidRecording("the selected device has no active audio format") }
        mode = settings.engine == .appleVoiceProcessing ? .appleVoiceProcessing : .none
        let token = UUID()
        captureToken = token
        self.directory = directory
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("microphone.caf"),
                                   settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let sink = AudioCaptureSink(file: file, meter: { [weak self] level in
            Task { @MainActor in
                guard let self, self.captureToken == token else { return }
                self.onMeter(level)
            }
        }, failed: { [weak self] message in
            Task { @MainActor in
                guard let self, self.captureToken == token else { return }
                self.onFailure(message)
            }
        })
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.consume(buffer) }
        self.sink = sink
        self.engine = engine
        do {
            try Task.checkCancellation()
            engine.prepare()
            try engine.start()
            if mode == .appleVoiceProcessing,
               !engine.inputNode.isVoiceProcessingEnabled || engine.inputNode.isVoiceProcessingBypassed {
                throw CrispyError.unavailable("The device did not retain enabled Apple voice processing after startup. Capture was stopped rather than labeled as enhanced.")
            }
            guard let activeUnit = engine.inputNode.audioUnit else {
                throw CrispyError.unavailable("The selected microphone disappeared during startup.")
            }
            actual = 0
            size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let activeQuery = AudioUnitGetProperty(activeUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &actual, &size)
            guard activeQuery == noErr, actual == identifier else {
                throw CrispyError.unavailable("The microphone route changed during startup. Capture was stopped rather than using a different device.")
            }
        } catch {
            stopHardware()
            throw error
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.captureToken == token else { return }
                    self.onFailure("The microphone route or format changed during capture. Recording was stopped; select the device again before starting a new meeting.")
                }
            }
        return RecordingDetails(deviceName: device.name, audioFilename: "microphone.caf", captureEngine: mode)
    }

    func stop() async throws -> RecordedAudio {
        guard engine != nil, let directory else { throw CrispyError.noActiveRecording }
        stopHardware()
        try sink?.finish()
        sink = nil
        let source = directory.appendingPathComponent("microphone.caf")
        let destination = directory.appendingPathComponent(mode == .appleVoiceProcessing ? "mic.voiceprocessed.wav" : "mic.wav")
        let summary = try await AudioFiles.convertToWAV(source: source, destination: destination, sampleRate: 48_000)
        self.directory = nil
        onMeter(0)
        return RecordedAudio(url: destination, duration: summary.duration, captureEngine: mode)
    }

    func cancel() async throws -> RecordedAudio? {
        guard let directory else { return nil }
        stopHardware()
        defer { self.directory = nil; sink = nil; onMeter(0) }
        try sink?.finish()
        let source = directory.appendingPathComponent("microphone.caf")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let file = try AVAudioFile(forReading: source)
        guard file.length > 0 else { return nil }
        return RecordedAudio(url: source, duration: Double(file.length) / file.fileFormat.sampleRate, captureEngine: mode)
    }

    private func stopHardware() {
        captureToken = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
    }
}
