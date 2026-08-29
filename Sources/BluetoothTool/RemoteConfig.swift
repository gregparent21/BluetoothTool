import Foundation

/// What this Mac needs in order to act as the agent for one house.
///
/// Lives at `~/.config/multi-speaker/remote.json`, written by pasting a setup
/// code from the website rather than edited by hand:
///
/// ```json
/// {
///   "supabaseURL": "https://xxxx.supabase.co",
///   "anonKey": "eyJhbGciOi...",
///   "deviceToken": "ms_...",
///   "houseName": "Greg's House"
/// }
/// ```
///
/// Note what is *not* here. Earlier versions kept a Supabase `service_role`
/// key, which is unlimited access to every house in the project — fine when you
/// ran your own backend, unacceptable once one backend serves many people. The
/// device token replaces it: the server resolves it to exactly one house, and
/// the only two things it can do are publish that house's state and drain that
/// house's command queue.
///
/// Absent or malformed, the app runs local-only — the menu bar UI does not
/// depend on any of this.
struct RemoteConfig: Codable, Equatable {
    let supabaseURL: URL
    /// The project's public anon key. Grants nothing by itself; the token below
    /// is what identifies this Mac.
    let anonKey: String
    let deviceToken: String
    var houseName: String?

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/multi-speaker/remote.json")
    }

    static func load() -> RemoteConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RemoteConfig.self, from: data)
    }

    /// True when a file exists but doesn't parse — almost always a remote.json
    /// from the single-house version, which is worth saying out loud instead of
    /// silently falling back to local-only.
    static func isStale() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return (try? JSONDecoder().decode(RemoteConfig.self, from: data)) == nil
    }

    func save() throws {
        let directory = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            // The token is a credential, so keep the directory to this user.
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    static func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Setup codes

    /// Parse the blob the website hands the owner after they create a house.
    ///
    /// It is base64 of the JSON above behind a version prefix. The prefix earns
    /// its place: a code that has been truncated by a chat app decodes to
    /// garbage otherwise, and "that isn't a setup code" is a much better error
    /// than "the key was rejected" an hour later.
    static func decode(setupCode raw: String) throws -> RemoteConfig {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw SetupCodeError.notASetupCode }

        // Mail clients and Messages love to wrap long strings.
        let body = trimmed.dropFirst(prefix.count)
            .components(separatedBy: .whitespacesAndNewlines).joined()

        guard let data = Data(base64Encoded: body) else { throw SetupCodeError.corrupt }
        guard let config = try? JSONDecoder().decode(RemoteConfig.self, from: data) else {
            throw SetupCodeError.corrupt
        }
        guard config.deviceToken.hasPrefix("ms_"), !config.anonKey.isEmpty else {
            throw SetupCodeError.corrupt
        }
        return config
    }

    private static let prefix = "MSPK1-"

    enum SetupCodeError: LocalizedError {
        case notASetupCode
        case corrupt

        var errorDescription: String? {
            switch self {
            case .notASetupCode:
                return "That doesn't look like a setup code. Copy the whole thing, starting with MSPK1-."
            case .corrupt:
                return "That setup code is incomplete. Copy it again from the website."
            }
        }
    }
}
