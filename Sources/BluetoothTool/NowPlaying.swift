import Foundation
import os

/// What Spotify is currently doing, as far as the remote UI needs to know.
struct NowPlaying: Equatable, Codable {
    var isPlaying: Bool
    var track: String
    var artist: String
    var album: String
    var artworkURL: String?
}

/// Playback control via Spotify's AppleScript dictionary.
///
/// The Mac is already the thing playing the audio, so there is no reason to
/// involve Spotify's Web API and its OAuth dance — the local scripting
/// interface gives us transport control and now-playing for free. It does
/// require Automation permission (the first call raises the system prompt);
/// until that is granted every call quietly returns nil.
enum SpotifyControl {

    private static let log = Logger(subsystem: "com.bluetoothtool", category: "Spotify")

    /// NSAppleScript is not thread-safe and compiling is slow enough to matter
    /// at poll rate, so scripts are compiled once and always run on this queue.
    private static let queue = DispatchQueue(label: "com.bluetoothtool.spotify")

    private static let stateScript = compile("""
        if application "Spotify" is not running then return "stopped"
        tell application "Spotify"
            if player state is stopped then return "stopped"
            return ((player state as text) & "\\n" & name of current track & "\\n" ¬
                & artist of current track & "\\n" & album of current track & "\\n" ¬
                & artwork url of current track)
        end tell
        """)

    private static let playPauseScript = compile(command("playpause"))
    private static let nextScript = compile(command("next track"))
    private static let previousScript = compile(command("previous track"))

    /// Spotify skips to the very start of the track on the first `previous
    /// track`, so going back a song reliably takes two.
    private static func command(_ body: String) -> String {
        """
        if application "Spotify" is not running then return
        tell application "Spotify" to \(body)
        """
    }

    private static func compile(_ source: String) -> NSAppleScript? {
        NSAppleScript(source: source)
    }

    // MARK: - Reading

    static func nowPlaying() -> NowPlaying? {
        guard let output = run(stateScript), output != "stopped" else { return nil }
        let fields = output.components(separatedBy: "\n")
        guard fields.count >= 4 else { return nil }
        let artwork = fields.count > 4 ? fields[4].trimmingCharacters(in: .whitespaces) : ""
        return NowPlaying(
            isPlaying: fields[0] == "playing",
            track: fields[1],
            artist: fields[2],
            album: fields[3],
            artworkURL: artwork.isEmpty ? nil : artwork
        )
    }

    // MARK: - Transport

    static func playPause() { _ = run(playPauseScript) }
    static func next() { _ = run(nextScript) }

    static func previous() {
        _ = run(previousScript)
        _ = run(previousScript)
    }

    // MARK: - Plumbing

    /// Runs on the scripting queue and blocks until Spotify answers. Callers are
    /// off the main actor, so a slow AppleEvent can't stall the menu.
    private static func run(_ script: NSAppleScript?) -> String? {
        guard let script else { return nil }
        return queue.sync {
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                // -600 is "app isn't running", which is normal and not worth logging.
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                if code != -600 {
                    log.error("AppleScript failed: \(String(describing: error[NSAppleScript.errorMessage]))")
                }
                return nil
            }
            return result.stringValue
        }
    }
}
