import Foundation
import os

/// A speaker as the website sees it. No house id: the device token the agent
/// presents is what decides which house these rows belong to, so the agent has
/// no way to name — or mistakenly overwrite — anyone else's.
struct RemoteSpeaker: Codable, Equatable {
    let address: String
    let name: String
    let is_connected: Bool
    let is_selected: Bool
    let volume: Double
    let supports_volume: Bool
    let is_muted: Bool
    let supports_mute: Bool
    let delay_ms: Int
}

/// Playback as the website sees it.
struct RemotePlayback: Codable, Equatable {
    let is_playing: Bool
    let track: String?
    let artist: String?
    let album: String?
    let artwork_url: String?
    let output_active: Bool
}

/// Everything the website renders, in one comparable lump so we only upload
/// when something actually changed.
struct RemoteSnapshot: Equatable {
    var speakers: [RemoteSpeaker]
    var playback: RemotePlayback
}

/// One instruction from a phone.
struct RemoteCommand: Decodable {
    let id: Int
    let kind: String
    let address: String?
    let value: Double?
}

/// Bridges the local audio engine to the hosted Supabase project so a phone on
/// the internet can drive it.
///
/// The entire API surface is two RPCs — `agent_publish` and `agent_poll` —
/// authenticated by a device token rather than a Supabase session. That is
/// deliberate: this process runs unattended on someone's kitchen Mac, so it
/// should hold a credential that is scoped to one house, revocable from the
/// website, and not something that needs refreshing.
///
/// Commands are polled rather than streamed over Realtime: a websocket buys
/// perhaps half a second of latency on a volume nudge and costs a dependency
/// plus a reconnect state machine. The *browser* still gets Realtime push for
/// state, which is where responsiveness is actually noticeable.
actor RemoteControl {

    private let config: RemoteConfig
    private let session = URLSession(configuration: .ephemeral)
    private let log = Logger(subsystem: "com.bluetoothtool", category: "Remote")

    private var pollTask: Task<Void, Never>?
    private var lastPublished: RemoteSnapshot?
    private var lastPublishedAt: Date?
    /// Reported to the UI so a broken relay is visible rather than silent.
    private(set) var lastError: String?

    private static let pollInterval = Duration.milliseconds(750)

    /// Republish unchanged state this often. The website uses the resulting
    /// timestamp to tell "nothing is happening" from "the Mac went to sleep",
    /// which is the difference between a working page and a mystery.
    private static let heartbeat: TimeInterval = 30

    init(config: RemoteConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    /// Begin polling. `handler` runs on the main actor for each command, in the
    /// order the website issued them.
    func start(handler: @escaping @MainActor (RemoteCommand) -> Void) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drainCommands(handler: handler)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Publishing

    func publish(_ snapshot: RemoteSnapshot) async {
        let stale = lastPublishedAt.map { Date().timeIntervalSince($0) >= Self.heartbeat } ?? true
        guard snapshot != lastPublished || stale else { return }

        struct Body: Encodable {
            let p_token: String
            let p_speakers: [RemoteSpeaker]
            let p_playback: RemotePlayback
        }

        do {
            var request = try makeRequest(rpc: "agent_publish")
            request.httpBody = try JSONEncoder().encode(
                Body(p_token: config.deviceToken,
                     p_speakers: snapshot.speakers,
                     p_playback: snapshot.playback)
            )
            try await send(request)
            lastPublished = snapshot
            lastPublishedAt = Date()
            lastError = nil
        } catch {
            // Keep lastPublished unchanged so the next tick retries.
            lastError = error.localizedDescription
            log.error("publish failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Commands

    private func drainCommands(handler: @escaping @MainActor (RemoteCommand) -> Void) async {
        struct Body: Encodable { let p_token: String }
        do {
            var request = try makeRequest(rpc: "agent_poll")
            request.httpBody = try JSONEncoder().encode(Body(p_token: config.deviceToken))
            let data = try await send(request)
            // agent_poll marks these consumed in the same statement that returns
            // them, so there is no second call and no chance of replaying one.
            let commands = try JSONDecoder().decode([RemoteCommand].self, from: data)
            for command in commands {
                await MainActor.run { handler(command) }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("command poll failed: \(error.localizedDescription)")
        }
    }

    // MARK: - HTTP

    private func makeRequest(rpc: String) throws -> URLRequest {
        guard let url = URL(string: "\(config.supabaseURL.absoluteString)/rest/v1/rpc/\(rpc)") else {
            throw RemoteError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.noResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    enum RemoteError: LocalizedError {
        case badURL
        case noResponse
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "The Supabase URL in this Mac's setup code isn't valid."
            case .noResponse: return "No response from the server."
            case .http(let code, let body):
                // A revoked device raises from inside the RPC, which PostgREST
                // reports as 400 with the message in the body — worth showing,
                // because "revoke" is a button someone may have just pressed.
                if body.contains("Unknown device token") {
                    return "This Mac has been disconnected from its house. Paste a new setup code."
                }
                if code == 401 || code == 403 { return "The server rejected this Mac's credentials." }
                return "Server returned HTTP \(code). \(body.prefix(120))"
            }
        }
    }
}
