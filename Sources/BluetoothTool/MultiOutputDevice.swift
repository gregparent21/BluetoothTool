import CoreAudio
import Foundation
import os

/// One speaker in the stack, plus how far to hold its audio back.
///
/// Speakers in the same room rarely start a sample at the same instant — a
/// portable speaker can trail earbuds by tens of milliseconds — and a stacked
/// device does no alignment of its own. Delaying the *early* speakers until
/// they match the latest one is what removes the echo.
struct AggregateMember: Equatable {
    let uid: String
    /// Extra output delay in milliseconds. 0 plays as early as the hardware allows.
    var delayMilliseconds: Int
}

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
    /// Members currently baked into the aggregate, in order.
    private(set) var members: [AggregateMember] = []

    private let log = Logger(subsystem: "com.bluetoothtool", category: "MultiOutput")

    var isActive: Bool { deviceID != nil }

    // MARK: - Lifecycle

    /// Make the aggregate contain exactly `wanted`, recreating it if membership
    /// or any member's delay changed.
    ///
    /// Returns the aggregate's device ID, or nil if there is nothing to play to.
    @discardableResult
    func synchronize(members wanted: [AggregateMember]) async -> AudioDeviceID? {
        guard !wanted.isEmpty else {
            destroy()
            return nil
        }
        if let existing = deviceID, wanted == members {
            return existing
        }

        // The HAL has no supported way to re-stack a live aggregate, and
        // `latency-out` is only read when the device is built, so both a
        // membership change and a delay change mean tear down and rebuild.
        // Remember whether we were the default output so the switch is
        // invisible to whatever is already playing.
        let wasDefault = deviceID != nil && AudioSystem.defaultOutputDeviceID == deviceID
        destroy()

        // coreaudiod publishes the removal asynchronously; recreating under the
        // same UID before it lands fails or hands back the dying device.
        await waitForRemoval()

        guard let created = create(members: wanted) else { return nil }
        deviceID = created
        members = wanted
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
        members = []
    }

    // MARK: - Creation

    private func create(members wanted: [AggregateMember]) -> AudioDeviceID? {
        // The clock source. Every other member gets drift-corrected onto it, so
        // prefer a wired/built-in device when one is present: its clock is far
        // more stable than a Bluetooth link's.
        let main = clockSource(among: wanted.map(\.uid))

        let subDevices: [[String: Any]] = wanted.map { member in
            var entry: [String: Any] = [
                kAudioSubDeviceUIDKey: member.uid,
                kAudioSubDeviceDriftCompensationKey: member.uid == main ? 0 : 1,
                kAudioSubDeviceDriftCompensationQualityKey: kAudioSubDeviceDriftCompensationHighQuality,
            ]
            if member.delayMilliseconds > 0 {
                entry[kAudioSubDeviceExtraOutputLatencyKey] = delayFrames(member)
            }
            return entry
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

    /// The delay the HAL actually stored for each member, in sample frames.
    ///
    /// Reads the aggregate's composition back rather than trusting what was
    /// asked for — `latency-out` is accepted silently, so this is the only way
    /// to confirm a delay really landed.
    nonisolated static func appliedOutputDelays(of aggregate: AudioDeviceID) -> [String: Int] {
        var address = CA.address(kAudioAggregateDevicePropertyComposition)
        var composition: CFDictionary? = nil
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &composition) {
            AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, $0)
        }
        guard status == noErr,
              let dictionary = composition as? [String: Any],
              let subDevices = dictionary[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        else { return [:] }

        return subDevices.reduce(into: [:]) { result, sub in
            guard let uid = sub[kAudioSubDeviceUIDKey] as? String else { return }
            result[uid] = sub[kAudioSubDeviceExtraOutputLatencyKey] as? Int ?? 0
        }
    }

    /// `latency-out` counts sample frames, so the conversion needs the rate of
    /// the device being delayed rather than a fixed 44.1k assumption.
    private func delayFrames(_ member: AggregateMember) -> Int {
        let rate = AudioSystem.device(withUID: member.uid).map { AudioSystem.sampleRate(of: $0.id) } ?? 44_100
        return Int((Double(member.delayMilliseconds) / 1000.0 * rate).rounded())
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
