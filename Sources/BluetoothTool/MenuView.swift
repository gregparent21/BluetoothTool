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

    var body: some View {
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
