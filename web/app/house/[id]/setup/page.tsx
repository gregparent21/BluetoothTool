"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import {
  db,
  inviteURL,
  isConfigured,
  setupCode,
  type Device,
  type House,
} from "@/lib/supabase";
import { useSession } from "@/lib/useSession";
import { SignInPanel } from "@/components/SignIn";
import { NotConfigured } from "@/components/NotConfigured";
import { Copyable } from "@/components/Copyable";

export default function SetupPage() {
  const { id } = useParams<{ id: string }>();
  const { user, loading } = useSession();

  const [house, setHouse] = useState<House | null>(null);
  const [devices, setDevices] = useState<Device[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [code, setCode] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [h, d] = await Promise.all([
      db().from("houses").select("*").eq("id", id).maybeSingle(),
      db()
        .from("devices")
        .select("id, house_id, name, created_at, last_seen_at")
        .eq("house_id", id)
        .order("created_at"),
    ]);
    setHouse((h.data ?? null) as House | null);
    setDevices((d.data ?? []) as Device[]);
    setLoaded(true);
  }, [id]);

  useEffect(() => {
    if (user) load();
  }, [user, load]);

  async function makeCode() {
    setBusy(true);
    setError(null);
    const { data, error } = await db().rpc("create_device", {
      p_house: id,
      p_name: "Mac",
    });
    setBusy(false);
    if (error) return setError(error.message);
    setCode(setupCode(data as string, house?.name ?? "House"));
    load();
  }

  async function revoke(deviceId: string) {
    const { error } = await db().from("devices").delete().eq("id", deviceId);
    if (error) return setError(error.message);
    load();
  }

  async function rotate() {
    setBusy(true);
    setError(null);
    const { error } = await db().rpc("rotate_invite_code", { p_house: id });
    setBusy(false);
    if (error) return setError(error.message);
    load();
  }

  if (!isConfigured) return <NotConfigured />;
  if (loading) return <main className="centered">Loading…</main>;
  if (!user) return <SignInPanel next={`/house/${id}/setup`} heading="Sign in to continue" />;
  if (!loaded) return <main className="centered">Loading…</main>;

  if (!house || house.owner_id !== user.id) {
    return (
      <main className="centered">
        <div className="banner error">
          Only the person who hosts this house can change its setup.
        </div>
        <Link className="link-btn" href={`/house/${id}`}>
          Back to the controls
        </Link>
      </main>
    );
  }

  return (
    <main>
      <div className="topbar">
        <Link href={`/house/${id}`} className="back" aria-label="Back">
          ‹
        </Link>
        <h1>Set up {house.name}</h1>
      </div>

      {error && <div className="banner error">{error}</div>}

      <ol className="setup">
        <li>
          <h2>Pick the computer</h2>
          <p>
            Everything runs from <b>one Mac</b>, and it is the machine that
            actually plays the music. Choose the one that lives in the house,
            stays plugged in, and sits near the speakers — a desktop or a laptop
            that stays on the counter, not the one you take to work.
          </p>
          <p className="fine">
            Bluetooth range is the real limit here, so closer to the middle of
            the house is better than closer to the router.
          </p>
        </li>

        <li>
          <h2>Pair every speaker to it</h2>
          <p>
            On that Mac, open{" "}
            <b>System&nbsp;Settings → Bluetooth</b> and pair each speaker you
            want in the house. They all connect to this one computer — nothing
            pairs to your phone.
          </p>
          <p className="fine">
            Two or three speakers is the realistic ceiling. They share one radio,
            and macOS drops to a lower-quality codec as you add more.
          </p>
        </li>

        <li>
          <h2>Install Multi-Speaker on it</h2>
          <p>
            Build and run the app on that Mac, then look for the speaker icon in
            the menu bar. It has no Dock icon and no window.
          </p>
          <Copyable label="In Terminal, from the project folder" value={"./build.sh\nopen build/BluetoothTool.app"} />
        </li>

        <li>
          <h2>Connect it to this house</h2>
          <p>
            Make a setup code here, then paste it into the app: menu bar icon →{" "}
            <b>Set up remote…</b>
          </p>

          {code ? (
            <>
              <Copyable label="Setup code" value={code} big />
              <p className="fine warn-text">
                This is shown once and never again. It lets that Mac publish to
                this house, so treat it like a password — if you lose it, make a
                new one and revoke the old below.
              </p>
            </>
          ) : (
            <button className="primary" onClick={makeCode} disabled={busy}>
              {busy ? "…" : devices.length ? "Make another setup code" : "Make a setup code"}
            </button>
          )}

          {devices.length > 0 && (
            <div className="device-list">
              {devices.map((d) => (
                <div key={d.id} className="device">
                  <div>
                    <div className="name">{d.name}</div>
                    <div className="status">
                      {d.last_seen_at
                        ? `Last checked in ${relative(d.last_seen_at)}`
                        : "Never checked in — the code hasn't been pasted yet"}
                    </div>
                  </div>
                  <button className="link-btn danger" onClick={() => revoke(d.id)}>
                    Revoke
                  </button>
                </div>
              ))}
            </div>
          )}
        </li>

        <li>
          <h2>Share it with your friends</h2>
          <p>
            Anyone with this link can sign in and control the speakers in this
            house — and only this house.
          </p>
          <Copyable label="Invite link" value={inviteURL(house.invite_code)} />
          <p className="fine">
            Making a new link stops every old one from working. People who
            already joined keep their access.
          </p>
          <button className="link-btn danger" onClick={rotate} disabled={busy}>
            Make a new link
          </button>
        </li>
      </ol>

      <p className="fine">
        The Mac has to be awake with Multi-Speaker running for any of this to do
        anything — it is the thing playing the music, and the website is only a
        remote control for it.
      </p>
    </main>
  );
}

function relative(iso: string) {
  const seconds = Math.round((Date.now() - Date.parse(iso)) / 1000);
  if (seconds < 90) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}
