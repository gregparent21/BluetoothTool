import Foundation
import IOBluetooth
import os

/// A paired Bluetooth audio device, whether or not it is currently connected.
struct BluetoothAudioDevice: Identifiable, Hashable {
    /// Normalized MAC address (lowercase, dash-separated) — also the join key
    /// to the CoreAudio device UID.
    let id: String
    let name: String
    let isConnected: Bool
}

enum BluetoothError: LocalizedError {
    case deviceNotFound
    case connectFailed(IOReturn)
    case audioDeviceNeverAppeared

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "That device is no longer paired with this Mac."
        case .connectFailed(let code):
            return BluetoothError.explain(code)
        case .audioDeviceNeverAppeared:
            return "Connected, but the device never offered an audio output. Try re-pairing it."
        }
    }

    /// IOReturn codes surface as large negative numbers that mean nothing to a
    /// user; the ones Bluetooth actually produces map to concrete advice.
    private static func explain(_ code: IOReturn) -> String {
        switch code {
        case kIOReturnTimeout:
            return "Timed out. Make sure the speaker is powered on, in range, and not already connected to another device."
        case kIOReturnNoDevice, kIOReturnNotFound:
            return "The Mac couldn't find it. Power it on and bring it closer."
        case kIOReturnBusy, kIOReturnExclusiveAccess:
            return "It's busy — probably connected to a phone or another computer. Disconnect it there first."
        case kIOReturnNotOpen, kIOReturnNotPermitted:
            return "The Mac wasn't allowed to connect. Try unpairing and re-pairing it in System Settings."
        default:
            return "Bluetooth refused the connection (IOReturn \(code))."
        }
    }
}

enum BluetoothAudio {

    private static let log = Logger(subsystem: "com.bluetoothtool", category: "Bluetooth")

    /// Every paired device that advertises the Audio major class — headphones,
    /// earbuds, speakers — excluding mice, phones and the like.
    static func pairedAudioDevices() -> [BluetoothAudioDevice] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired
            .filter { $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) }
            .compactMap { device in
                guard let address = device.addressString else { return nil }
                return BluetoothAudioDevice(
                    id: AudioDevice.normalizeAddress(address),
                    name: device.name ?? address,
                    isConnected: device.isConnected()
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func device(withAddress address: String) -> IOBluetoothDevice? {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.first {
            guard let addressString = $0.addressString else { return false }
            return AudioDevice.normalizeAddress(addressString) == address
        }
    }

    /// Open a baseband connection and wait for macOS to bring up A2DP behind it.
    ///
    /// `openConnection` returns as soon as the link is up, which is well before
    /// the HAL publishes an output device, so success means "an audio device
    /// with this address showed up", not merely "the radio connected".
    static func connect(address: String) async throws {
        guard let device = device(withAddress: address) else { throw BluetoothError.deviceNotFound }

        if !device.isConnected() {
            let result = await Task.detached(priority: .userInitiated) {
                device.openConnection()
            }.value
            guard result == kIOReturnSuccess else {
                log.error("openConnection failed for \(address): \(result)")
                throw BluetoothError.connectFailed(result)
            }
        }

        // A2DP negotiation after link-up is typically 1–3s on Bluetooth.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if audioDevice(forAddress: address) != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw BluetoothError.audioDeviceNeverAppeared
    }

    static func disconnect(address: String) async {
        guard let device = device(withAddress: address) else { return }
        await Task.detached(priority: .userInitiated) {
            _ = device.closeConnection()
        }.value
    }

    /// The CoreAudio output device backing a Bluetooth address, if it is connected.
    static func audioDevice(forAddress address: String) -> AudioDevice? {
        AudioSystem.outputDevices().first { $0.bluetoothAddress == address }
    }
}
