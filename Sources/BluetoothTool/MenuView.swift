import SwiftUI

/// Height of the speaker list's content, measured from the rows themselves.
///
/// `ScrollView` reports no intrinsic content height, so a `MenuBarExtra` window
/// sizing itself to fit its content resolves it to zero and the list vanishes —
/// a `maxHeight` alone only caps it, nothing gives it a floor. Measuring the
/// rows and setting a definite height is what keeps them on screen.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel

    /// Tallest the list may grow before it starts scrolling.
    private static let maxListHeight: CGFloat = 340

    @State private var listHeight: CGFloat = 0
    /// Swaps the whole menu for the setup form. A sheet would be the obvious
    /// choice, but sheets inside a MenuBarExtra window are unreliable — the
    /// popover dismisses itself out from under them.
    @State private var showingSetup = false

    var body: some View {
        if showingSetup {
            RemoteSetupPanel(model: model, isPresented: $showingSetup)
                .frame(width: 340)
        } else {
            speakerMenu
        }
    }

    private var speakerMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.speakers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.speakers) { speaker in
                            SpeakerRow(speaker: speaker, model: model)
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                        }
                    )
                }
                .frame(height: min(max(listHeight, 1), Self.maxListHeight))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            }

            if let error = model.errorMessage {
                Divider()
                errorBanner(error)
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isActive ? "hifispeaker.2.fill" : "hifispeaker.2")
                .foregroundStyle(model.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.outputDeviceName)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.statusMessage ?? (model.isActive ? "Active" : "Not playing"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let house = model.houseName {
                    Text(house)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()

            // Only meaningful once remote.json exists; a failing relay is worth
            // seeing here, because the website just goes quiet when it breaks.
            if model.isRemoteEnabled {
                Image(systemName: model.remoteError == nil
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(model.remoteError == nil ? Color.accentColor : .orange)
                    .help(model.remoteError ?? "Remote control online")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No paired Bluetooth speakers")
                .font(.system(size: 12, weight: .medium))
            Text("Pair headphones or a speaker in System Settings, then reopen this menu.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.dismissError() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(model.isActive ? "Stop" : "Play to \(model.selectedCount) device\(model.selectedCount == 1 ? "" : "s")") {
                model.isActive ? model.deactivate() : model.activate()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isActive && model.selectedCount == 0)

            Spacer()

            Button(model.isRemoteEnabled ? "Remote…" : "Set up remote…") {
                showingSetup = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.hasStaleRemoteConfig ? Color.orange : Color.accentColor)
            .font(.system(size: 12))

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct SpeakerRow: View {
    let speaker: Speaker
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { speaker.isSelected },
                    set: { _ in model.toggleSelection(speaker.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 0) {
                    Text(speaker.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(statusColor)
                }

                Spacer(minLength: 4)

                if speaker.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if speaker.isConnected {
                    Button("Disconnect") { model.disconnect(speaker.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Connect") { model.connect(speaker.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
            }

            HStack(spacing: 6) {
                Button {
                    model.toggleMute(for: speaker.id)
                } label: {
                    Image(systemName: speaker.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(speaker.isMuted ? .orange : .secondary)
                .disabled(!speaker.supportsMute || !speaker.isConnected)

                Slider(
                    value: Binding(
                        get: { Double(speaker.volume) },
                        set: { model.setVolume(Float($0), for: speaker.id) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(!speaker.canAdjustVolume)

                Text(volumeLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.leading, 20)
            .opacity(speaker.canAdjustVolume ? 1 : 0.45)

            delayRow
                .padding(.leading, 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(speaker.isSelected ? Color.accentColor.opacity(0.07) : .clear)
    }

    /// Delay is a property of where the speaker sits in the room, so it stays
    /// adjustable even while the speaker is disconnected.
    private var delayRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 10))
                .frame(width: 14)
                .foregroundStyle(.secondary)

            Button {
                model.adjustDelay(by: -AppModel.delayStep, for: speaker.id)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(speaker.delayMilliseconds <= AppModel.delayRange.lowerBound)

            Text("\(speaker.delayMilliseconds) ms")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 52)

            Button {
                model.adjustDelay(by: AppModel.delayStep, for: speaker.id)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(speaker.delayMilliseconds >= AppModel.delayRange.upperBound)

            Text("delay")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if speaker.delayMilliseconds > 0 {
                Button("Reset") { model.resetDelay(for: speaker.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .foregroundStyle(speaker.delayMilliseconds > 0 ? Color.primary : .secondary)
    }

    private var statusText: String {
        if speaker.isBusy { return "Connecting…" }
        if !speaker.isConnected { return "Not connected" }
        if !speaker.volumeCapability.isControllable { return "Connected · no volume control" }
        return "Connected"
    }

    private var statusColor: Color {
        speaker.isConnected ? .secondary : .secondary.opacity(0.7)
    }

    private var volumeLabel: String {
        speaker.canAdjustVolume ? "\(Int((speaker.volume * 100).rounded()))%" : "—"
    }
}


/// Connects this Mac to a house by pasting the setup code the website shows the
/// house's owner.
///
/// Pasting is the whole interaction on purpose. The alternative — telling
/// people to create `~/.config/multi-speaker/remote.json` by hand — is fine for
/// the person who wrote the app and a wall for everyone who was handed it at a
/// party.
private struct RemoteSetupPanel: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var code = ""
    @State private var error: String?
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remote control")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }

            if model.isRemoteEnabled {
                connected
            } else {
                setupForm
            }
        }
        .padding(14)
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: model.remoteError == nil
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(model.remoteError == nil ? Color.accentColor : .orange)
                Text(model.houseName ?? "Connected")
                    .font(.system(size: 12, weight: .medium))
            }

            Text(model.remoteError ?? "This Mac is serving the house. Anyone with its invite link can control these speakers from their phone.")
                .font(.system(size: 11))
                .foregroundStyle(model.remoteError == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if confirmingDisconnect {
                Text("Stop serving this house? The speakers keep working locally.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    Button("Keep it") { confirmingDisconnect = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Disconnect this Mac…") { confirmingDisconnect = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            if let error { errorText(error) }
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasStaleRemoteConfig {
                Text("This Mac has settings from an older version that can no longer be used. Sign in on the website, open your house, and paste its new setup code.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("On the Multi-Speaker website, create a house and open its setup page. Paste the setup code it gives you here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $code)
                .font(.system(size: 10, design: .monospaced))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .scrollContentBackground(.hidden)

            HStack {
                Button("Paste") {
                    code = NSPasteboard.general.string(forType: .string) ?? ""
                    error = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error { errorText(error) }

            Text("Every speaker for the house pairs to this Mac, and this Mac is what plays the music. It has to stay awake with this app running.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func connect() {
        do {
            try model.applySetupCode(code)
            code = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func disconnect() {
        do {
            try model.disconnectRemote()
            confirmingDisconnect = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
