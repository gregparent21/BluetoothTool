"use client";

import { sendCommand, type Playback } from "@/lib/supabase";

/// Fixed transport bar. Mirrors Spotify on the Mac; the Mac is what's actually
/// playing, so these are just remote key presses.
export function NowPlayingBar({ houseId, playback }: { houseId: string; playback: Playback | null }) {
  const hasTrack = Boolean(playback?.track);

  return (
    <div className="player">
      <div className="player-inner">
        {playback?.artwork_url ? (
          // Plain <img>: the URL is Spotify's CDN and there is nothing for
          // next/image to optimise on a 48px thumbnail.
          // eslint-disable-next-line @next/next/no-img-element
          <img className="art" src={playback.artwork_url} alt="" />
        ) : (
          <div className="art" />
        )}

        <div className="track">
          <div className="track-name">{playback?.track ?? "Nothing playing"}</div>
          <div className="track-artist">
            {hasTrack ? playback?.artist : "Start something on the Mac"}
          </div>
        </div>

        <div className="transport">
          <button onClick={() => sendCommand(houseId, "previous")} aria-label="Previous">
            ⏮
          </button>
          <button onClick={() => sendCommand(houseId, "playpause")} aria-label="Play or pause">
            {playback?.is_playing ? "⏸" : "▶"}
          </button>
          <button onClick={() => sendCommand(houseId, "next")} aria-label="Next">
            ⏭
          </button>
        </div>
      </div>
    </div>
  );
}
