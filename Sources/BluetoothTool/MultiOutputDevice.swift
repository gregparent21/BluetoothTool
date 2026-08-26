import CoreAudio
import Foundation
import os

/// Owns the "stacked" aggregate device — what Audio MIDI Setup calls a
/// *Multi-Output Device*. macOS fans a single stream out to every sub-device
/// and drift-corrects the ones that aren't the clock source.
///
/// The device is created non-private so that other processes (Spotify, System
/// Settings) can see and select it. It lives only as long as this process, so
/// `destroy()` runs on quit to avoid leaving a stale entry behind.
@MainActor
final class MultiOutputDevice {

    nonisolated static let uid = "com.bluetoothtool.multi-output"
    nonisolated static let name = "Multi-Speaker"

    private(set) var deviceID: AudioDeviceID?
    /// Sub-device UIDs currently baked into the aggregate, in order.
    private(set) var memberUIDs: [String] = []

    private let log = Logger(subsystem: "com.bluetoothtool", category: "MultiOutput")

    var isActive: Bool { deviceID != nil }

    // MARK: - Lifecycle

    /// Make the aggregate contain exactly `uids`, recreating it if membership changed.
    ///
    /// Returns the aggregate's device ID, or nil if there is nothing to play to.
    @discardableResult
    func synchronize(memberUIDs uids: [String]) async -> AudioDeviceID? {
        guard !uids.isEmpty else {
            destroy()
            return nil
        }
        if let existing = deviceID, uids == memberUIDs {
            return existing
        }

        // The HAL has no supported way to re-stack a live aggregate, so
        // membership changes mean tear down and rebuild. Remember whether we
        // were the default output so the switch is invisible to whatever is
        // already playing.
        let wasDefault = deviceID != nil && AudioSystem.defaultOutputDeviceID == deviceID
        destroy()

        // coreaudiod publishes the removal asynchronously; recreating under the
        // same UID before it lands fails or hands back the dying device.
        await waitForRemoval()

        guard let created = create(memberUIDs: uids) else { return nil }
        deviceID = created
        memberUIDs = uids
        if wasDefault {
            await AudioSystem.setDefaultOutputVerified(created)
        }
        return created
    }

    private func waitForRemoval() async {
        for _ in 0..<20 {
            if AudioSystem.device(withUID: Self.uid) == nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        log.warning("Old aggregate device still present after 1s; recreating anyway")
    }

    func destroy() {
        adoptOrphanedDevice()
        guard let id = deviceID else { return }
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status != noErr {
            log.error("Failed to destroy aggregate device: \(status)")
        }
        deviceID = nil
        memberUIDs = []
    }

    // MARK: - Creation

    private func create(memberUIDs uids: [String]) -> AudioDeviceID? {
        // The clock source. Every other member gets drift-corrected onto it, so
        // prefer a wired/built-in device when one is present: its clock is far
        // more stable than a Bluetooth link's.
        let main = clockSource(among: uids)

        let subDevices: [[String: Any]] = uids.map { uid in
            [
                kAudioSubDeviceUIDKey: uid,
                kAudioSubDeviceDriftCompensationKey: uid == main ? 0 : 1,
                kAudioSubDeviceDriftCompensationQualityKey: kAudioSubDeviceDriftCompensationHighQuality,
            ]
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: Self.uid,
            kAudioAggregateDeviceNameKey: Self.name,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey: main,
            // Stacked == multi-output: the same audio to every member, rather
            // than members concatenated into one wide channel layout.
            kAudioAggregateDeviceIsStackedKey: 1,
            // Visible to every process, which is the whole point.
            kAudioAggregateDeviceIsPrivateKey: 0,
        ]

        var created = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &created)
        guard status == noErr, created != 0 else {
            log.error("Failed to create aggregate device: \(status)")
            return nil
        }
        return created
    }

    /// Wired devices make better clock sources than Bluetooth ones.
    private func clockSource(among uids: [String]) -> String {
        let devices = AudioSystem.outputDevices()
        let wired = uids.first { uid in
            guard let device = devices.first(where: { $0.uid == uid }) else { return false }
            return !device.isBluetooth
        }
        return wired ?? uids[0]
    }

    /// Reclaim an aggregate left behind by a previous run that crashed, so we
    /// don't accumulate duplicate "Multi-Speaker" entries in the output list.
    func adoptOrphanedDevice() {
        guard deviceID == nil else { return }
        if let existing = AudioSystem.device(withUID: Self.uid) {
            deviceID = existing.id
        }
    }
}
