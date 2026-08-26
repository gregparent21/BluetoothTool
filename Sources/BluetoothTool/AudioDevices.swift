import CoreAudio
import Foundation

/// A CoreAudio output device, as the HAL currently sees it.
///
/// Bluetooth devices only exist as `AudioDevice`s while they are connected — a
/// paired-but-idle speaker has no entry here at all.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let outputChannels: Int

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isAggregate: Bool {
        transportType == kAudioDeviceTransportTypeAggregate
    }

    /// Bluetooth output devices are named by MAC address, e.g.
    /// `70-8C-F2-E5-AB-AC:output`. That prefix is our join key back to
    /// IOBluetooth's paired-device list.
    var bluetoothAddress: String? {
        guard isBluetooth else { return nil }
        let head = uid.split(separator: ":").first.map(String.init) ?? uid
        return AudioDevice.normalizeAddress(head)
    }

    static func normalizeAddress(_ raw: String) -> String {
        raw.replacingOccurrences(of: ":", with: "-").lowercased()
    }
}

/// Which HAL elements actually accept a volume change on a given device.
///
/// This is not uniform: the built-in speakers expose one "main" element, while
/// AirPods expose no main element and one element per channel. Devices with no
/// AVRCP absolute-volume support expose nothing at all.
enum VolumeCapability: Equatable {
    case none
    case main
    case channels([AudioObjectPropertyElement])

    var isControllable: Bool { self != .none }
}

enum AudioSystem {

    // MARK: - Enumeration

    static func outputDevices() -> [AudioDevice] {
        let ids = CA.array(CA.systemObject, CA.address(kAudioHardwarePropertyDevices), of: AudioDeviceID.self)
        return ids.compactMap { device(for: $0) }
    }

    static func device(for id: AudioDeviceID) -> AudioDevice? {
        let channels = CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        guard channels > 0 else { return nil }
        guard let uid = CA.string(id, CA.address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = CA.string(id, CA.address(kAudioObjectPropertyName)) ?? uid
        let transport = CA.get(id, CA.address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
        return AudioDevice(id: id, uid: uid, name: name, transportType: transport, outputChannels: channels)
    }

    static func device(withUID uid: String) -> AudioDevice? {
        outputDevices().first { $0.uid == uid }
    }

    // MARK: - Default output

    static var defaultOutputDeviceID: AudioDeviceID? {
        CA.get(CA.systemObject, CA.address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioDeviceID(0))
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        CA.set(CA.systemObject, CA.address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    /// Set the default output and confirm it stuck.
    ///
    /// A freshly created aggregate device isn't reliably selectable for the
    /// first few hundred milliseconds: the write returns `noErr` but the
    /// property still reads back the old device. Retrying until it reads back
    /// is the only dependable way to land the switch.
    @discardableResult
    static func setDefaultOutputVerified(_ id: AudioDeviceID, attempts: Int = 8) async -> Bool {
        for attempt in 0..<attempts {
            setDefaultOutput(id)
            if attempt == 0, defaultOutputDeviceID == id { return true }
            try? await Task.sleep(for: .milliseconds(150))
            if defaultOutputDeviceID == id { return true }
        }
        return false
    }

    // MARK: - Volume

    static func volumeCapability(of device: AudioDeviceID, channels: Int) -> VolumeCapability {
        let main = CA.address(
            kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        )
        if CA.isSettable(device, main) { return .main }

        let perChannel = (1...max(channels, 1)).map(AudioObjectPropertyElement.init).filter { element in
            CA.isSettable(device, CA.address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ))
        }
        return perChannel.isEmpty ? .none : .channels(perChannel)
    }

    /// Current volume as 0...1, averaged across channels when there is no main element.
    static func volume(of device: AudioDeviceID, capability: VolumeCapability) -> Float? {
        func read(_ element: AudioObjectPropertyElement) -> Float? {
            CA.get(device, CA.address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ), initial: Float32(0))
        }

        switch capability {
        case .none:
            return nil
        case .main:
            return read(kAudioObjectPropertyElementMain)
        case .channels(let elements):
            let values = elements.compactMap(read)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Float(values.count)
        }
    }

    @discardableResult
    static func setVolume(_ value: Float, on device: AudioDeviceID, capability: VolumeCapability) -> Bool {
        let clamped = min(max(value, 0), 1)

        func write(_ element: AudioObjectPropertyElement) -> Bool {
            CA.set(device, CA.address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ), Float32(clamped))
        }

        switch capability {
        case .none:
            return false
        case .main:
            return write(kAudioObjectPropertyElementMain)
        case .channels(let elements):
            // `reduce` rather than `allSatisfy` so every channel is written even
            // if an earlier one fails.
            return elements.map(write).reduce(true) { $0 && $1 }
        }
    }

    // MARK: - Mute

    static func isMuteSupported(_ device: AudioDeviceID) -> Bool {
        CA.isSettable(device, CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput))
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        let value = CA.get(device, CA.address(
            kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        ), initial: UInt32(0)) ?? 0
        return value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool {
        CA.set(device, CA.address(
            kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        ), UInt32(muted ? 1 : 0))
    }
}
