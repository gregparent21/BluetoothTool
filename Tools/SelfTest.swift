import CoreAudio
import Foundation

/// Exercises the CoreAudio and IOBluetooth paths the app depends on, against
/// whatever hardware is actually attached. Run via ./selftest.sh.
///
/// Everything it changes (volumes, default output, the aggregate device, any
/// speaker it connects) is restored before it exits.
@main
struct SelfTest {

    static var connectSpeakers = CommandLine.arguments.contains("--connect")

    @MainActor
    static func main() async {
        // Captured before anything is created: once an aggregate exists macOS
        // may auto-select it, and we'd then "restore" to our own scratch device.
        let previous = AudioSystem.defaultOutputDeviceID
        let previousName = previous.flatMap(AudioSystem.device(for:))?.name ?? "unknown"

        section("Paired Bluetooth audio devices")
        var paired = BluetoothAudio.pairedAudioDevices()
        guard !paired.isEmpty else { return fail("No paired Bluetooth audio devices.") }
        for device in paired {
            print("  \(device.isConnected ? "●" : "○") \(device.name)  [\(device.id)]")
        }

        if connectSpeakers {
            section("Connecting disconnected speakers")
            for target in paired where !target.isConnected {
                print("  \(target.name)…")
                do {
                    try await BluetoothAudio.connect(address: target.id)
                    pass("connected")
                } catch {
                    fail(error.localizedDescription)
                }
            }
            paired = BluetoothAudio.pairedAudioDevices()
        } else {
            print("\n  (re-run with --connect to also power up disconnected speakers)")
        }

        section("Bluetooth → CoreAudio mapping")
        let live = paired.filter(\.isConnected).compactMap { device -> (BluetoothAudioDevice, AudioDevice)? in
            guard let audio = BluetoothAudio.audioDevice(forAddress: device.id) else {
                fail("\(device.name) is connected but has no CoreAudio output device")
                return nil
            }
            pass("\(device.name) → id=\(audio.id) uid=\(audio.uid) channels=\(audio.outputChannels)")
            return (device, audio)
        }
        guard !live.isEmpty else { return fail("Nothing connected to test with.") }

        section("Per-device volume control")
        for (device, audio) in live {
            let capability = AudioSystem.volumeCapability(of: audio.id, channels: audio.outputChannels)
            guard let original = AudioSystem.volume(of: audio.id, capability: capability) else {
                fail("\(device.name): no volume control (device doesn't report absolute volume to macOS)")
                continue
            }
            let probe = original > 0.5 ? original - 0.05 : original + 0.05
            _ = AudioSystem.setVolume(probe, on: audio.id, capability: capability)

            // coreaudiod propagates the change asynchronously, and Bluetooth
            // devices that quantize volume settle a step away from the request.
            var readBack: Float = -1
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(150))
                readBack = AudioSystem.volume(of: audio.id, capability: capability) ?? -1
                if abs(readBack - probe) < 0.02 { break }
            }
            _ = AudioSystem.setVolume(original, on: audio.id, capability: capability)

            if abs(readBack - probe) < 0.02 {
                pass("\(device.name): \(capability), wrote \(pct(probe)) read \(pct(readBack)), restored \(pct(original))")
            } else if abs(readBack - probe) < 0.07 {
                // One AVRCP step is 1/16; snapping to it still means the write landed.
                pass("\(device.name): \(capability), wrote \(pct(probe)) snapped to \(pct(readBack)) (device quantizes volume)")
            } else {
                fail("\(device.name): wrote \(pct(probe)) but read back \(pct(readBack))")
            }
        }

        section("Multi-output device over \(live.count) speaker(s)")
        let multiOutput = MultiOutputDevice()
        multiOutput.adoptOrphanedDevice()
        multiOutput.destroy()

        // Delay the second speaker so the composition read-back below has
        // something non-zero to prove.
        let members = live.enumerated().map { index, entry in
            AggregateMember(uid: entry.1.uid, delayMilliseconds: index == 1 ? 50 : 0)
        }
        guard let aggregateID = await multiOutput.synchronize(members: members),
              let aggregate = AudioSystem.device(for: aggregateID) else {
            return fail("Could not create the aggregate device.")
        }
        pass("created '\(aggregate.name)' with \(aggregate.outputChannels) output channels")

        section("Per-speaker delay")
        let applied = MultiOutputDevice.appliedOutputDelays(of: aggregateID)
        for member in members {
            let expected = member.delayMilliseconds
            guard let frames = applied[member.uid] else {
                fail("\(member.uid): no latency-out reported back")
                continue
            }
            let rate = AudioSystem.device(withUID: member.uid).map { AudioSystem.sampleRate(of: $0.id) } ?? 44_100
            let ms = Int((Double(frames) / rate * 1000).rounded())
            if ms == expected {
                pass("\(member.uid): \(expected) ms → \(frames) frames")
            } else {
                fail("\(member.uid): asked for \(expected) ms, HAL reports \(ms) ms")
            }
        }

        if AudioSystem.outputDevices().contains(where: { $0.id == aggregateID }) {
            pass("visible system-wide — other apps can select it")
        } else {
            fail("not visible in the global device list")
        }

        section("Default output switch")
        let switched = await AudioSystem.setDefaultOutputVerified(aggregateID)
        if switched {
            pass("'\(previousName)' → '\(aggregate.name)'")
        } else {
            fail("system did not switch to the aggregate device")
        }

        section("Volume control while inside the aggregate")
        for (device, audio) in live {
            let capability = AudioSystem.volumeCapability(of: audio.id, channels: audio.outputChannels)
            if let value = AudioSystem.volume(of: audio.id, capability: capability),
               AudioSystem.setVolume(value, on: audio.id, capability: capability) {
                pass("\(device.name): still writable at \(pct(value))")
            } else {
                fail("\(device.name): volume became unwritable once stacked")
            }
        }

        section("Cleanup")
        if let previous { await AudioSystem.setDefaultOutputVerified(previous) }
        multiOutput.destroy()
        pass("default output restored to '\(previousName)', aggregate destroyed")
    }

    // MARK: - Output

    static func section(_ title: String) { print("\n── \(title) ".padding(toLength: 64, withPad: "─", startingAt: 0)) }
    static func pass(_ message: String) { print("  ✓ \(message)") }
    static func fail(_ message: String) { print("  ✗ \(message)") }
    static func pct(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }
}
