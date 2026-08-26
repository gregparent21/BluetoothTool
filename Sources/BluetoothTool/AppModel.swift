import CoreAudio
import Foundation
import SwiftUI

/// One row in the UI: a paired Bluetooth speaker plus whatever CoreAudio
/// currently knows about it.
struct Speaker: Identifiable, Equatable {
    let id: String              // normalized MAC address
    var name: String
    var isConnected: Bool
    var audioDeviceID: AudioDeviceID?
    var isSelected: Bool
    var volume: Float
    var volumeCapability: VolumeCapability
    var isMuted: Bool
    var supportsMute: Bool
    var isBusy: Bool

    var canAdjustVolume: Bool { isConnected && volumeCapability.isControllable }
}

@MainActor
final class AppModel: ObservableObject {

    /// One model per app. The app delegate needs to reach it during termination,
    /// which is outside any SwiftUI scope.
    static let shared = AppModel()

    @Published private(set) var speakers: [Speaker] = []
    @Published private(set) var isActive = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    private let multiOutput = MultiOutputDevice()
    private var selectedAddresses: Set<String>
    private var deviceListToken: CA.ListenerToken?
    private var defaultOutputToken: CA.ListenerToken?
    private var refreshTimer: Timer?
    private var previousDefaultOutputUID: String?
    private var isSyncing = false

    /// Volumes we just wrote ourselves. Polling would otherwise snap the slider
    /// back to a stale reading mid-drag.
    private var recentLocalVolumeWrites: [String: Date] = [:]

    private static let selectionKey = "selectedSpeakerAddresses"

    var outputDeviceName: String { MultiOutputDevice.name }

    var selectedCount: Int { speakers.filter(\.isSelected).count }

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.selectionKey) ?? []
        selectedAddresses = Set(stored)
        multiOutput.adoptOrphanedDevice()
        // A leftover aggregate from a crashed run is not "active" state we want
        // to inherit — start clean.
        multiOutput.destroy()

        observeSystemChanges()
        refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Observation

    private func observeSystemChanges() {
        deviceListToken = CA.observe(CA.systemObject, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        defaultOutputToken = CA.observe(CA.systemObject, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Refresh

    func refresh() {
        let paired = BluetoothAudio.pairedAudioDevices()
        let outputs = AudioSystem.outputDevices()
        let byAddress = Dictionary(
            outputs.compactMap { device in device.bluetoothAddress.map { ($0, device) } },
            uniquingKeysWith: { first, _ in first }
        )
        let busyAddresses = Set(speakers.filter(\.isBusy).map(\.id))
        let now = Date()

        speakers = paired.map { device in
            let audio = byAddress[device.id]
            var capability = VolumeCapability.none
            var volume: Float = 0
            var muted = false
            var supportsMute = false

            if let audio {
                capability = AudioSystem.volumeCapability(of: audio.id, channels: audio.outputChannels)
                supportsMute = AudioSystem.isMuteSupported(audio.id)
                muted = supportsMute && AudioSystem.isMuted(audio.id)

                let justWrote = recentLocalVolumeWrites[device.id].map { now.timeIntervalSince($0) < 1.0 } ?? false
                if justWrote, let cached = speakers.first(where: { $0.id == device.id })?.volume {
                    volume = cached
                } else {
                    volume = AudioSystem.volume(of: audio.id, capability: capability) ?? 0
                }
            }

            return Speaker(
                id: device.id,
                name: device.name,
                isConnected: device.isConnected && audio != nil,
                audioDeviceID: audio?.id,
                isSelected: selectedAddresses.contains(device.id),
                volume: volume,
                volumeCapability: capability,
                isMuted: muted,
                supportsMute: supportsMute,
                isBusy: busyAddresses.contains(device.id)
            )
        }

        if isActive {
            Task { await syncAggregateMembership() }
        }
    }

    // MARK: - Selection

    func toggleSelection(_ address: String) {
        if selectedAddresses.contains(address) {
            selectedAddresses.remove(address)
        } else {
            selectedAddresses.insert(address)
        }
        UserDefaults.standard.set(Array(selectedAddresses), forKey: Self.selectionKey)
        refresh()

        if isActive {
            Task { await connectSelectedThenSync() }
        }
    }

    // MARK: - Volume

    func setVolume(_ value: Float, for address: String) {
        guard let index = speakers.firstIndex(where: { $0.id == address }),
              let deviceID = speakers[index].audioDeviceID else { return }

        speakers[index].volume = value
        recentLocalVolumeWrites[address] = Date()
        AudioSystem.setVolume(value, on: deviceID, capability: speakers[index].volumeCapability)
    }

    func toggleMute(for address: String) {
        guard let index = speakers.firstIndex(where: { $0.id == address }),
              let deviceID = speakers[index].audioDeviceID,
              speakers[index].supportsMute else { return }

        let newValue = !speakers[index].isMuted
        speakers[index].isMuted = newValue
        AudioSystem.setMuted(newValue, on: deviceID)
    }

    // MARK: - Per-device connection

    func connect(_ address: String) {
        Task { await performConnect(address) }
    }

    func disconnect(_ address: String) {
        Task {
            setBusy(true, for: address)
            await BluetoothAudio.disconnect(address: address)
            setBusy(false, for: address)
            refresh()
        }
    }

    private func performConnect(_ address: String) async {
        setBusy(true, for: address)
        defer {
            setBusy(false, for: address)
            refresh()
        }
        do {
            try await BluetoothAudio.connect(address: address)
        } catch {
            errorMessage = "\(name(of: address)): \(error.localizedDescription)"
        }
    }

    private func setBusy(_ busy: Bool, for address: String) {
        guard let index = speakers.firstIndex(where: { $0.id == address }) else { return }
        speakers[index].isBusy = busy
    }

    private func name(of address: String) -> String {
        speakers.first { $0.id == address }?.name ?? address
    }

    // MARK: - Activation

    func activate() {
        Task {
            errorMessage = nil
            guard selectedCount > 0 else {
                errorMessage = "Pick at least one speaker first."
                return
            }
            previousDefaultOutputUID = AudioSystem.defaultOutputDeviceID
                .flatMap(AudioSystem.device(for:))
                .map(\.uid)

            await connectSelectedThenSync()

            guard let deviceID = multiOutput.deviceID else {
                errorMessage = "Couldn't create the output device. Is anything connected?"
                return
            }
            isActive = true
            guard await AudioSystem.setDefaultOutputVerified(deviceID) else {
                isActive = false
                errorMessage = "macOS wouldn't switch output to \(MultiOutputDevice.name). Try again."
                return
            }
            refresh()
        }
    }

    func deactivate() {
        Task {
            isActive = false
            statusMessage = nil

            // Move the system off the aggregate before destroying it, otherwise
            // macOS picks a fallback output on its own.
            if let uid = previousDefaultOutputUID, let device = AudioSystem.device(withUID: uid) {
                await AudioSystem.setDefaultOutputVerified(device.id)
            }
            multiOutput.destroy()
            previousDefaultOutputUID = nil
            refresh()
        }
    }

    private func connectSelectedThenSync() async {
        let targets = speakers.filter { $0.isSelected && !$0.isConnected }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for address in targets {
                group.addTask { @MainActor in await self.performConnect(address) }
            }
        }
        refresh()
        await syncAggregateMembership()
    }

    /// Rebuild the aggregate so it holds exactly the selected, connected speakers.
    ///
    /// Serialized: the 2s refresh timer would otherwise be able to start a
    /// second rebuild while one is still tearing the old device down.
    private func syncAggregateMembership() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let uids = speakers
            .filter { $0.isSelected && $0.isConnected }
            .compactMap { $0.audioDeviceID }
            .compactMap { AudioSystem.device(for: $0)?.uid }

        let deviceID = await multiOutput.synchronize(memberUIDs: uids)

        guard isActive else { return }
        if deviceID == nil {
            statusMessage = "No connected speakers."
        } else {
            statusMessage = "Playing to \(uids.count) speaker\(uids.count == 1 ? "" : "s")."
        }
    }

    func dismissError() { errorMessage = nil }

    /// Tear the aggregate down so it doesn't outlive the app in the output list.
    /// Called from `applicationWillTerminate`, which cannot await — so this is
    /// a best-effort synchronous restore rather than the verified path.
    func shutDown() {
        if let uid = previousDefaultOutputUID, let device = AudioSystem.device(withUID: uid) {
            AudioSystem.setDefaultOutput(device.id)
        }
        isActive = false
        multiOutput.destroy()
    }
}
