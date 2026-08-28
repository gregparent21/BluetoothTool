import Foundation
import os

/// A speaker as the website sees it.
struct RemoteSpeaker: Codable, Equatable {
    let room_id: String
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

/// Everything the website renders, in one comparable lump so we only upload
/// when something actually changed.
struct RemoteSnapshot: Equatable {
    var speakers: [RemoteSpeaker]
    var nowPlaying: NowPlaying?
    var isActive: Bool
}

/// One instruction from a phone.
struct RemoteCommand: Decodable {
    let id: Int
    let kind: String
    let address: String?
    let value: Double?
}

/// Bridges the local audio engine to a Supabase project so a phone on the
/// internet can drive it.
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
    /// Reported to the UI so a broken relay is visible rather than silent.
    private(set) var lastError: String?

    private static let pollInterval = Duration.milliseconds(750)

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
        guard snapshot != lastPublished else { return }
        do {
            try await upsertSpeakers(snapshot.speakers)
            try await pruneSpeakers(keeping: snapshot.speakers.map(\.address))
            try await upsertPlayback(snapshot.nowPlaying, isActive: snapshot.isActive)
            lastPublished = snapshot
            lastError = nil
        } catch {
            // Keep lastPublished unchanged so the next tick retries.
            lastError = error.localizedDescription
            log.error("publish failed: \(error.localizedDescription)")
        }
    }

    private func upsertSpeakers(_ speakers: [RemoteSpeaker]) async throws {
        guard !speakers.isEmpty else { return }
        var request = try makeRequest(path: "speakers", query: "on_conflict=room_id,address")
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(speakers)
        try await send(request)
    }

    /// Drop rows for speakers that are no longer paired, so the site doesn't
    /// show devices that have been forgotten in System Settings.
    private func pruneSpeakers(keeping addresses: [String]) async throws {
        guard !addresses.isEmpty else { return }
        let list = addresses.map { "\"\($0)\"" }.joined(separator: ",")
        let query = "room_id=eq.\(config.roomID)&address=not.in.(\(list))"
        var request = try makeRequest(path: "speakers", query: query)
        request.httpMethod = "DELETE"
        try await send(request)
    }

    private func upsertPlayback(_ nowPlaying: NowPlaying?, isActive: Bool) async throws {
        struct Row: Encodable {
            let room_id: String
            let is_playing: Bool
            let track: String?
            let artist: String?
            let album: String?
            let artwork_url: String?
            let output_active: Bool
        }
        let row = Row(
            room_id: config.roomID,
            is_playing: nowPlaying?.isPlaying ?? false,
            track: nowPlaying?.track,
            artist: nowPlaying?.artist,
            album: nowPlaying?.album,
            artwork_url: nowPlaying?.artworkURL,
            output_active: isActive
        )
        var request = try makeRequest(path: "playback", query: "on_conflict=room_id")
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode([row])
        try await send(request)
    }

    // MARK: - Commands

    private func drainCommands(handler: @escaping @MainActor (RemoteCommand) -> Void) async {
        do {
            let query = "room_id=eq.\(config.roomID)&consumed_at=is.null&order=id.asc&limit=50"
            var request = try makeRequest(path: "commands", query: query)
            request.httpMethod = "GET"
            let data = try await send(request)
            let commands = try JSONDecoder().decode([RemoteCommand].self, from: data)
            guard !commands.isEmpty else { return }

            for command in commands {
                await MainActor.run { handler(command) }
            }
            try await markConsumed(commands.map(\.id))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("command poll failed: \(error.localizedDescription)")
        }
    }

    private func markConsumed(_ ids: [Int]) async throws {
        let list = ids.map(String.init).joined(separator: ",")
        var request = try makeRequest(path: "commands", query: "id=in.(\(list))")
        request.httpMethod = "PATCH"
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["consumed_at": ISO8601DateFormatter().string(from: Date())]
        )
        try await send(request)
    }

    // MARK: - HTTP

    private func makeRequest(path: String, query: String) throws -> URLRequest {
        guard let url = URL(string: "\(config.supabaseURL.absoluteString)/rest/v1/\(path)?\(query)") else {
            throw RemoteError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(config.serviceKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.serviceKey)", forHTTPHeaderField: "Authorization")
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
            case .badURL: return "The Supabase URL in remote.json isn't valid."
            case .noResponse: return "No response from Supabase."
            case .http(let code, let body):
                if code == 401 || code == 403 { return "Supabase rejected the key (HTTP \(code))." }
                return "Supabase returned HTTP \(code). \(body.prefix(120))"
            }
        }
    }
}
