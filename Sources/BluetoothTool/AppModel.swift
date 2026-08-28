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
    /// Extra output delay, in milliseconds, used to line this speaker up with
    /// the others. Stored per speaker whether or not it is currently connected.
    var delayMilliseconds: Int

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
    @Published private(set) var nowPlaying: NowPlaying?
    /// nil when the remote is off or healthy; a message when the relay is failing.
    @Published private(set) var remoteError: String?
    @Published private(set) var isRemoteEnabled = false

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

    /// Delay per speaker address, in milliseconds. Survives launches because it
    /// describes the room's physical layout, which doesn't change between runs.
    private var delaysByAddress: [String: Int]
    /// Rebuilding the aggregate interrupts playback, so arrow presses are
    /// coalesced and only applied once the user stops adjusting.
    private var delaySettleTask: Task<Void, Never>?
    private var isAdjustingDelay = false

    private let remoteConfig = RemoteConfig.load()
    private var remote: RemoteControl?
    /// Guards against a slow publish overlapping the next 2s tick.
    private var isPublishing = false

    private static let selectionKey = "selectedSpeakerAddresses"
    private static let delaysKey = "speakerDelayMilliseconds"

    /// How much one arrow press moves the delay, and how far it can go.
    static let delayStep = 5
    static let delayRange = 0...500

    var outputDeviceName: String { MultiOutputDevice.name }

    var selectedCount: Int { speakers.filter(\.isSelected).count }

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.selectionKey) ?? []
        selectedAddresses = Set(stored)
        delaysByAddress = UserDefaults.standard.dictionary(forKey: Self.delaysKey) as? [String: Int] ?? [:]
        multiOutput.adoptOrphanedDevice()
        // A leftover aggregate from a crashed run is not "active" state we want
        // to inherit — start clean.
        multiOutput.destroy()

        observeSystemChanges()
        refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        startRemoteIfConfigured()
    }

    // MARK: - Remote control

    private func startRemoteIfConfigured() {
        guard let remoteConfig else { return }
        let remote = RemoteControl(config: remoteConfig)
        self.remote = remote
        isRemoteEnabled = true
        Task {
            await remote.start { [weak self] command in
                self?.apply(command)
            }
        }
    }

    /// Push local state out and pull Spotify's. Runs off the 2s refresh tick.
    private func updateRemote() async {
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }

        // AppleEvents round-trip to another process, so never on the main actor.
        let playing = await Task.detached(priority: .utility) { SpotifyControl.nowPlaying() }.value
        if playing != nowPlaying { nowPlaying = playing }

        guard let remote, let roomID = remoteConfig?.roomID else { return }
        let snapshot = RemoteSnapshot(
            speakers: speakers.map {
                RemoteSpeaker(
                    room_id: roomID,
                    address: $0.id,
                    name: $0.name,
                    is_connected: $0.isConnected,
                    is_selected: $0.isSelected,
                    volume: Double($0.volume),
                    supports_volume: $0.volumeCapability.isControllable,
                    is_muted: $0.isMuted,
                    supports_mute: $0.supportsMute,
                    delay_ms: $0.delayMilliseconds
                )
            },
            nowPlaying: playing,
            isActive: isActive
        )
        await remote.publish(snapshot)

        let failure = await remote.lastError
        if remoteError != failure { remoteError = failure }
    }

    private func apply(_ command: RemoteCommand) {
        switch command.kind {
        case "set_volume":
            if let address = command.address, let value = command.value {
                setVolume(Float(min(max(value, 0), 1)), for: address)
            }
        case "set_muted":
            if let address = command.address, let value = command.value {
                setMuted(value != 0, for: address)
            }
        case "set_selected":
            if let address = command.address, let value = command.value {
                setSelected(value != 0, for: address)
            }
        case "set_delay":
            if let address = command.address, let value = command.value {
                setDelay(Int(value), for: address)
            }
        case "set_active":
            if let value = command.value {
                value != 0 ? activate() : deactivate()
            }
        case "playpause":
            Task.detached(priority: .userInitiated) { SpotifyControl.playPause() }
        case "next":
            Task.detached(priority: .userInitiated) { SpotifyControl.next() }
        case "previous":
            Task.detached(priority: .userInitiated) { SpotifyControl.previous() }
        default:
            break
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
                isBusy: busyAddresses.contains(device.id),
                delayMilliseconds: delaysByAddress[device.id] ?? 0
            )
        }

        if isActive {
            Task { await syncAggregateMembership() }
        }
        Task { await updateRemote() }
    }

    // MARK: - Selection

    func toggleSelection(_ address: String) {
        setSelected(!selectedAddresses.contains(address), for: address)
    }

    /// Explicit form, used by the remote: two phones sending "toggle" at once
    /// would cancel out, where two "on"s agree.
    func setSelected(_ selected: Bool, for address: String) {
        let changed = selected
            ? selectedAddresses.insert(address).inserted
            : selectedAddresses.remove(address) != nil
        guard changed else { return }

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
        guard let index = speakers.firstIndex(where: { $0.id == address }) else { return }
        setMuted(!speakers[index].isMuted, for: address)
    }

    func setMuted(_ muted: Bool, for address: String) {
        guard let index = speakers.firstIndex(where: { $0.id == address }),
              let deviceID = speakers[index].audioDeviceID,
              speakers[index].supportsMute else { return }

        speakers[index].isMuted = muted
        AudioSystem.setMuted(muted, on: deviceID)
    }

    // MARK: - Delay

    /// Nudge a speaker's delay by `delta` milliseconds, clamped to `delayRange`.
    func adjustDelay(by delta: Int, for address: String) {
        let current = delaysByAddress[address] ?? 0
        setDelay(current + delta, for: address)
    }

    func resetDelay(for address: String) {
        setDelay(0, for: address)
    }

    func setDelay(_ value: Int, for address: String) {
        let clamped = min(max(value, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        guard clamped != delaysByAddress[address] ?? 0 else { return }

        if clamped == 0 {
            delaysByAddress.removeValue(forKey: address)
        } else {
            delaysByAddress[address] = clamped
        }
        UserDefaults.standard.set(delaysByAddress, forKey: Self.delaysKey)
        refresh()

        // The new value shows in the UI immediately; the aggregate only takes
        // it once presses stop, so holding an arrow costs one rebuild, not ten.
        guard isActive else { return }
        isAdjustingDelay = true
        statusMessage = "Applying delay…"
        delaySettleTask?.cancel()
        delaySettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.isAdjustingDelay = false
            await self.syncAggregateMembership()
        }
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
        // Mid-adjustment the committed delays and the displayed ones disagree;
        // rebuilding now would apply a half-finished value and glitch playback.
        guard !isSyncing, !isAdjustingDelay else { return }
        isSyncing = true
        defer { isSyncing = false }

        let members = speakers
            .filter { $0.isSelected && $0.isConnected }
            .compactMap { speaker -> AggregateMember? in
                guard let deviceID = speaker.audioDeviceID,
                      let uid = AudioSystem.device(for: deviceID)?.uid else { return nil }
                return AggregateMember(uid: uid, delayMilliseconds: speaker.delayMilliseconds)
            }

        let deviceID = await multiOutput.synchronize(members: members)

        guard isActive else { return }
        if deviceID == nil {
            statusMessage = "No connected speakers."
        } else {
            statusMessage = "Playing to \(members.count) speaker\(members.count == 1 ? "" : "s")."
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
