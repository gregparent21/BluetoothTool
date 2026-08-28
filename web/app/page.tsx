"use client";

import { useEffect, useState } from "react";
import {
  isConfigured,
  roomId,
  sendCommand,
  supabase,
  type Playback,
  type Speaker,
} from "@/lib/supabase";
import { SpeakerCard } from "@/components/SpeakerCard";
import { NowPlayingBar } from "@/components/NowPlayingBar";

export default function Page() {
  const [speakers, setSpeakers] = useState<Speaker[]>([]);
  const [playback, setPlayback] = useState<Playback | null>(null);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!supabase) return;

    async function load() {
      const [s, p] = await Promise.all([
        supabase!.from("speakers").select("*").eq("room_id", roomId),
        supabase!.from("playback").select("*").eq("room_id", roomId).maybeSingle(),
      ]);
      if (s.data) setSpeakers(sort(s.data as Speaker[]));
      if (p.data) setPlayback(p.data as Playback);
      setLoaded(true);
    }
    load();

    // The Mac republishes on every change, so rather than patch rows by hand we
    // just re-read the small tables whenever anything moves.
    const channel = supabase
      .channel(`room:${roomId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "speakers", filter: `room_id=eq.${roomId}` },
        load,
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "playback", filter: `room_id=eq.${roomId}` },
        load,
      )
      .subscribe();

    return () => {
      supabase!.removeChannel(channel);
    };
  }, []);

  if (!isConfigured) {
    return (
      <main>
        <h1>Multi-Speaker</h1>
        <div className="banner">
          Not configured yet. Copy <code>.env.local.example</code> to{" "}
          <code>.env.local</code> and fill in your Supabase URL, anon key, and room
          id — then restart the dev server.
        </div>
      </main>
    );
  }

  const connected = speakers.filter((s) => s.is_connected);
  const playingTo = speakers.filter((s) => s.is_selected && s.is_connected).length;

  return (
    <main>
      <h1>Multi-Speaker</h1>
      <p className="sub">
        {playback?.output_active
          ? `Playing to ${playingTo} speaker${playingTo === 1 ? "" : "s"}`
          : "Output is off"}
      </p>

      {loaded && connected.length === 0 && (
        <div className="banner">
          No speakers are connected. Turn them on, or wake the Mac — it has to be
          awake and running Multi-Speaker for this page to do anything.
        </div>
      )}

      <div className="master">
        <div>
          <div className="name">House output</div>
          <div className="status">
            {playback?.output_active ? "On" : "Off"} · Multi-Speaker
          </div>
        </div>
        <input
          type="checkbox"
          className="toggle"
          checked={Boolean(playback?.output_active)}
          onChange={(e) => sendCommand("set_active", null, e.target.checked ? 1 : 0)}
          aria-label="House output"
        />
      </div>

      {!loaded ? (
        <div className="empty">Loading…</div>
      ) : speakers.length === 0 ? (
        <div className="empty">
          Nothing published yet. Is Multi-Speaker running on the Mac?
        </div>
      ) : (
        speakers.map((s) => <SpeakerCard key={s.address} speaker={s} />)
      )}

      <NowPlayingBar playback={playback} />
    </main>
  );
}

/// Connected speakers first, then alphabetical — the ones you can actually
/// affect belong at the top on a phone screen.
function sort(list: Speaker[]) {
  return [...list].sort((a, b) => {
    if (a.is_connected !== b.is_connected) return a.is_connected ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
}
