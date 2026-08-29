"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import {
  db,
  isConfigured,
  sendCommand,
  supabase,
  type House,
  type Playback,
  type Speaker,
} from "@/lib/supabase";
import { useSession } from "@/lib/useSession";
import { SignInPanel } from "@/components/SignIn";
import { NotConfigured } from "@/components/NotConfigured";
import { SpeakerCard } from "@/components/SpeakerCard";
import { NowPlayingBar } from "@/components/NowPlayingBar";
import { ShareButton } from "@/components/ShareButton";

/// The Mac republishes at least every 30s, so silence for twice that means it
/// is asleep, quit, or off the network — the single most common reason for the
/// page to look fine and do nothing.
const OFFLINE_AFTER_MS = 70_000;

export default function HousePage() {
  const { id } = useParams<{ id: string }>();
  const { user, loading } = useSession();

  const [house, setHouse] = useState<House | null>(null);
  const [speakers, setSpeakers] = useState<Speaker[]>([]);
  const [playback, setPlayback] = useState<Playback | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [denied, setDenied] = useState(false);
  const [now, setNow] = useState(() => Date.now());

  const load = useCallback(async () => {
    const [h, s, p] = await Promise.all([
      db().from("houses").select("*").eq("id", id).maybeSingle(),
      db().from("speakers").select("*").eq("house_id", id),
      db().from("playback").select("*").eq("house_id", id).maybeSingle(),
    ]);
    // RLS turns "not a member" into an empty read rather than an error.
    if (!h.data) setDenied(true);
    else setHouse(h.data as House);
    setSpeakers(sortSpeakers((s.data ?? []) as Speaker[]));
    setPlayback((p.data ?? null) as Playback | null);
    setLoaded(true);
  }, [id]);

  useEffect(() => {
    if (!user || !supabase) return;
    // Bound once so the cleanup closure keeps the non-null narrowing.
    const client = supabase;
    load();

    // The Mac republishes whole rows on every change, so rather than patch
    // state by hand we re-read the two small tables whenever anything moves.
    const channel = client
      .channel(`house:${id}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "speakers", filter: `house_id=eq.${id}` },
        load,
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "playback", filter: `house_id=eq.${id}` },
        load,
      )
      .subscribe();

    return () => {
      client.removeChannel(channel);
    };
  }, [user, id, load]);

  // Drives the offline banner; nothing else here depends on wall-clock time.
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 15_000);
    return () => clearInterval(t);
  }, []);

  if (!isConfigured) return <NotConfigured />;
  if (loading) return <main className="centered">Loading…</main>;
  if (!user) return <SignInPanel next={`/house/${id}`} heading="Sign in to continue" />;
  if (loaded && denied) {
    return (
      <main className="centered">
        <div className="banner error">
          You don&rsquo;t have access to this house. Ask whoever hosts it for
          their invite link.
        </div>
        <Link className="link-btn" href="/">
          Your houses
        </Link>
      </main>
    );
  }
  if (!loaded || !house) return <main className="centered">Loading…</main>;

  const isOwner = house.owner_id === user.id;
  const lastSeen = playback ? Date.parse(playback.updated_at) : NaN;
  const macOffline = !Number.isNaN(lastSeen) && now - lastSeen > OFFLINE_AFTER_MS;
  const neverConnected = Number.isNaN(lastSeen) || speakers.length === 0;
  const playingTo = speakers.filter((s) => s.is_selected && s.is_connected).length;

  return (
    <main>
      <div className="topbar">
        <Link href="/" className="back" aria-label="All houses">
          ‹
        </Link>
        <h1>{house.name}</h1>
        <ShareButton code={house.invite_code} houseName={house.name} />
      </div>
      <p className="sub">
        {playback?.output_active
          ? `Playing to ${playingTo} speaker${playingTo === 1 ? "" : "s"}`
          : "Output is off"}
      </p>

      {macOffline && !neverConnected && (
        <div className="banner warn">
          The computer for this house hasn&rsquo;t checked in for a minute. Wake
          it up and make sure Multi-Speaker is still running.
        </div>
      )}

      {neverConnected && (
        <div className="banner">
          {isOwner ? (
            <>
              No computer is set up for this house yet.{" "}
              <Link href={`/house/${id}/setup`}>Set one up →</Link>
            </>
          ) : (
            <>
              Nothing to control yet — whoever hosts this house still has to set
              up the computer the speakers are paired to.
            </>
          )}
        </div>
      )}

      {isOwner && !neverConnected && (
        <Link href={`/house/${id}/setup`} className="fine-link">
          Computer &amp; invite settings
        </Link>
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
          onChange={(e) => sendCommand(id, "set_active", null, e.target.checked ? 1 : 0)}
          aria-label="House output"
        />
      </div>

      {speakers.length === 0 ? (
        <div className="empty">No speakers published yet.</div>
      ) : (
        speakers.map((s) => <SpeakerCard key={s.address} houseId={id} speaker={s} />)
      )}

      <NowPlayingBar houseId={id} playback={playback} />
    </main>
  );
}

/// Connected speakers first, then alphabetical — the ones you can actually
/// affect belong at the top on a phone screen.
function sortSpeakers(list: Speaker[]) {
  return [...list].sort((a, b) => {
    if (a.is_connected !== b.is_connected) return a.is_connected ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
}
