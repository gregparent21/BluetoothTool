"use client";

import { useEffect, useRef, useState } from "react";
import { sendCommand, type Speaker } from "@/lib/supabase";

const DELAY_STEP = 5;
const DELAY_MAX = 500;

/**
 * One speaker. Volume and delay are driven optimistically — the slider has to
 * track the thumb at 60fps, and a round trip to the Mac is ~1s — so local state
 * leads and the realtime value only takes over once the user lets go.
 */
export function SpeakerCard({ speaker }: { speaker: Speaker }) {
  const [volume, setVolume] = useState(speaker.volume);
  const [delay, setDelay] = useState(speaker.delay_ms);
  const dragging = useRef(false);
  const volumeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const delayTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Accept pushed state only while the user isn't mid-gesture, otherwise the
  // slider fights the thumb.
  useEffect(() => {
    if (!dragging.current) setVolume(speaker.volume);
  }, [speaker.volume]);

  useEffect(() => {
    if (!delayTimer.current) setDelay(speaker.delay_ms);
  }, [speaker.delay_ms]);

  function onVolume(next: number) {
    setVolume(next);
    dragging.current = true;
    if (volumeTimer.current) clearTimeout(volumeTimer.current);
    // Coalesce the stream of input events into ~7 writes/sec.
    volumeTimer.current = setTimeout(() => {
      sendCommand("set_volume", speaker.address, next);
      dragging.current = false;
    }, 140);
  }

  function nudgeDelay(delta: number) {
    const next = Math.min(Math.max(delay + delta, 0), DELAY_MAX);
    if (next === delay) return;
    setDelay(next);
    if (delayTimer.current) clearTimeout(delayTimer.current);
    // Each change rebuilds the aggregate on the Mac, so wait for the taps to
    // stop before committing.
    delayTimer.current = setTimeout(() => {
      sendCommand("set_delay", speaker.address, next);
      delayTimer.current = null;
    }, 600);
  }

  const status = !speaker.is_connected
    ? "Not connected"
    : speaker.supports_volume
      ? "Connected"
      : "Connected · no volume control";

  return (
    <div
      className={`card${speaker.is_selected ? " on" : ""}${speaker.is_connected ? "" : " offline"}`}
    >
      <div className="card-head">
        <div className="name-wrap" style={{ flex: 1, minWidth: 0 }}>
          <div className="name">{speaker.name}</div>
          <div className="status">{status}</div>
        </div>
        <input
          type="checkbox"
          className="toggle"
          checked={speaker.is_selected}
          disabled={!speaker.is_connected}
          onChange={(e) =>
            sendCommand("set_selected", speaker.address, e.target.checked ? 1 : 0)
          }
          aria-label={`Play to ${speaker.name}`}
        />
      </div>

      <div className="row">
        <button
          className="icon-btn"
          disabled={!speaker.supports_mute || !speaker.is_connected}
          onClick={() =>
            sendCommand("set_muted", speaker.address, speaker.is_muted ? 0 : 1)
          }
          aria-label={speaker.is_muted ? "Unmute" : "Mute"}
        >
          {speaker.is_muted ? "🔇" : "🔊"}
        </button>
        <input
          type="range"
          min={0}
          max={1}
          step={0.01}
          value={volume}
          disabled={!speaker.supports_volume || !speaker.is_connected}
          onChange={(e) => onVolume(Number(e.target.value))}
          aria-label={`${speaker.name} volume`}
        />
        <span className="pct">
          {speaker.supports_volume && speaker.is_connected
            ? `${Math.round(volume * 100)}%`
            : "—"}
        </span>
      </div>

      <div className="row">
        <button
          className="icon-btn"
          onClick={() => nudgeDelay(-DELAY_STEP)}
          disabled={delay <= 0}
          aria-label="Less delay"
        >
          ‹
        </button>
        <span className={`delay-value${delay === 0 ? " zero" : ""}`}>{delay} ms</span>
        <button
          className="icon-btn"
          onClick={() => nudgeDelay(DELAY_STEP)}
          disabled={delay >= DELAY_MAX}
          aria-label="More delay"
        >
          ›
        </button>
        <span className="delay-label">
          delay{delay > 0 ? "" : " · raise if this speaker sounds early"}
        </span>
        {delay > 0 && (
          <button className="icon-btn" onClick={() => nudgeDelay(-delay)} aria-label="Reset delay">
            ⟲
          </button>
        )}
      </div>
    </div>
  );
}
