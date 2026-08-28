import Foundation

/// Credentials for the Supabase project that relays commands from the website.
///
/// Read from `~/.config/multi-speaker/remote.json` rather than compiled in, so
/// the service key never lands in the repository or in the signed bundle:
///
/// ```json
/// {
///   "supabaseURL": "https://xxxx.supabase.co",
///   "serviceKey": "eyJhbGciOi...",
///   "roomID": "0f8f...",
///   "roomName": "Greg's House"
/// }
/// ```
///
/// Absent or malformed, the app simply runs local-only — the menu bar UI does
/// not depend on any of this.
struct RemoteConfig: Codable, Equatable {
    let supabaseURL: URL
    /// The service-role key. This process is trusted and local; the website
    /// gets the far weaker anon key instead.
    let serviceKey: String
    let roomID: String
    var roomName: String?

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/multi-speaker/remote.json")
    }

    static func load() -> RemoteConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RemoteConfig.self, from: data)
    }
}
