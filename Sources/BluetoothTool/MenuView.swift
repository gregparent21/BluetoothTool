import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel

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
                }
                .frame(maxHeight: 340)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(speaker.isSelected ? Color.accentColor.opacity(0.07) : .clear)
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
