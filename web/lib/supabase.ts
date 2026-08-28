import { createClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

export const roomId = process.env.NEXT_PUBLIC_ROOM_ID ?? "";

/// False until .env.local is filled in, which lets the page render a setup
/// message instead of crashing the build on a missing key.
export const isConfigured = Boolean(url && anonKey && roomId);

export const supabase = isConfigured ? createClient(url!, anonKey!) : null;

export type Speaker = {
  address: string;
  name: string;
  is_connected: boolean;
  is_selected: boolean;
  volume: number;
  supports_volume: boolean;
  is_muted: boolean;
  supports_mute: boolean;
  delay_ms: number;
};

export type Playback = {
  is_playing: boolean;
  track: string | null;
  artist: string | null;
  album: string | null;
  artwork_url: string | null;
  output_active: boolean;
};

export type CommandKind =
  | "set_volume"
  | "set_muted"
  | "set_selected"
  | "set_delay"
  | "set_active"
  | "playpause"
  | "next"
  | "previous";

/**
 * Queue an instruction for the Mac. Fire-and-forget: the authoritative result
 * arrives back as a realtime state update within a second or so, so there is
 * nothing useful to await here.
 */
export async function sendCommand(
  kind: CommandKind,
  address?: string | null,
  value?: number | null,
) {
  if (!supabase) return;
  const { error } = await supabase.from("commands").insert({
    room_id: roomId,
    kind,
    address: address ?? null,
    value: value ?? null,
  });
  if (error) console.error("command failed", kind, error.message);
}
