import AVFoundation
import CoreAudio
import Foundation

public struct AudioDeviceInfo: Codable, Identifiable, Equatable, Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var transport: UInt32
    public var isDefaultInput: Bool

    public init(id: UInt32, uid: String, name: String, inputChannels: Int, outputChannels: Int,
                transport: UInt32 = 0, isDefaultInput: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.transport = transport
        self.isDefaultInput = isDefaultInput
    }

    public var isVirtual: Bool {
        transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate ||
        ["blackhole", "loopback", "soundflower", "teams audio", "krisp", "aggregate", "virtual", "multi-output", "driver"]
            .contains { name.localizedCaseInsensitiveContains($0) }
    }

    public var isLoopbackCandidate: Bool {
        inputChannels > 0 && outputChannels > 0 &&
        ["blackhole", "loopback", "soundflower", "teams audio"].contains { name.localizedCaseInsensitiveContains($0) }
    }
}

public struct DeviceDiagnostics: Codable, Sendable {
    public let version: String
    public let microphonePermission: String
    public let devices: [AudioDeviceInfo]
    public let loopbackCandidates: [AudioDeviceInfo]
    public let nativeVirtualMicrophoneRunning: Bool
    public let farEndAudioCaptured: Bool
    public let explanation: String

    public init(devices: [AudioDeviceInfo], permission: String) {
        version = CrispyVersion.current
        microphonePermission = permission
        self.devices = devices
        loopbackCandidates = devices.filter(\.isLoopbackCandidate)
        nativeVirtualMicrophoneRunning = false
        farEndAudioCaptured = false
        explanation = """
        The native app records only the microphone you select. Optional screen capture is video only, not remote participant/system audio. \
        Native live virtual-microphone routing is not implemented. The preserved CLI's RNNoise live path requires a separately configured, \
        compatible existing loopback device. Candidate names and duplex channels do not prove compatibility or routing. \
        No driver is installed and no system audio routing is changed by this app.
        """
    }

    public static func preferredInput(_ devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        let hardware = devices.filter { $0.inputChannels > 0 && !$0.isVirtual }
        return hardware.first(where: \.isDefaultInput) ?? hardware.first
    }
}

public enum AudioDevices {
    public static var permission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Authorized for this application"
        case .notDetermined: return "Not requested — requested only when you click Record"
        case .denied: return "Denied — enable RAPP Crispy in System Settings → Privacy & Security → Microphone"
        case .restricted: return "Restricted by system policy"
        @unknown default: return "Unknown"
        }
    }

    public static func snapshot() throws -> DeviceDiagnostics {
        DeviceDiagnostics(devices: try list(), permission: permission)
    }

    public static func list() throws -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0 else { return [] }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = identifiers.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(result)
        let defaultInput = try integer(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice)
        return try identifiers.map { id in
            AudioDeviceInfo(id: id, uid: try string(object: id, selector: kAudioDevicePropertyDeviceUID),
                name: try string(object: id, selector: kAudioObjectPropertyName),
                inputChannels: try channels(object: id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: try channels(object: id, scope: kAudioObjectPropertyScopeOutput),
                transport: try integer(object: id, selector: kAudioDevicePropertyTransportType),
                isDefaultInput: id == defaultInput)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CrispyError.unavailable("CoreAudio device query failed (OSStatus \(status)).") }
    }
    private static func string(object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status)
        guard let value else { throw CrispyError.unavailable("CoreAudio returned no device name or identifier.") }
        return value.takeRetainedValue() as String
    }
    private static func integer(object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
        return value
    }
    private static func channels(object: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size))
        guard size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, memory))
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
