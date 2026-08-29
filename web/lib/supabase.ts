import { createClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

/// False until .env.local is filled in, which lets the app render a setup
/// message instead of crashing the build on a missing key.
export const isConfigured = Boolean(url && anonKey);

export const supabaseUrl = url ?? "";
export const supabaseAnonKey = anonKey ?? "";

export const supabase = isConfigured
  ? createClient(url!, anonKey!, {
      auth: {
        // PKCE keeps the access token out of the redirect URL. The exchange is
        // done in the browser by detectSessionInUrl, which is why the callback
        // page has nothing to do but wait.
        flowType: "pkce",
        detectSessionInUrl: true,
        persistSession: true,
        autoRefreshToken: true,
      },
    })
  : null;

/// Throws rather than returning null, for the paths that only run behind a
/// configuration check and would otherwise need a null test at every call.
export function db() {
  if (!supabase) throw new Error("Supabase is not configured");
  return supabase;
}

// ------------------------------------------------------------------ types

export type House = {
  id: string;
  owner_id: string;
  name: string;
  invite_code: string;
  created_at: string;
};

export type Membership = { role: "owner" | "member"; houses: House };

export type Device = {
  id: string;
  house_id: string;
  name: string;
  created_at: string;
  last_seen_at: string | null;
};

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
  /// Touched on every publish, including the agent's 30s heartbeat, so it
  /// doubles as "when did the Mac last check in".
  updated_at: string;
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

// --------------------------------------------------------------- commands

/**
 * Queue an instruction for a house's Mac. Fire-and-forget: the authoritative
 * result arrives back as a realtime state update within a second or so, so
 * there is nothing useful to await here.
 */
export async function sendCommand(
  houseId: string,
  kind: CommandKind,
  address?: string | null,
  value?: number | null,
) {
  if (!supabase) return;
  const { error } = await supabase.from("commands").insert({
    house_id: houseId,
    kind,
    address: address ?? null,
    value: value ?? null,
  });
  if (error) console.error("command failed", kind, error.message);
}

// -------------------------------------------------------------- setup code

/**
 * The blob the owner pastes into the Mac app. Base64 so that a line break
 * introduced by a chat app or a mail client cannot silently corrupt a key, and
 * prefixed so the app can tell a truncated paste from a wrong one.
 */
export function setupCode(deviceToken: string, houseName: string) {
  const payload = JSON.stringify({
    supabaseURL: supabaseUrl,
    anonKey: supabaseAnonKey,
    deviceToken,
    houseName,
  });
  // btoa is latin1-only; a house called "Café" would throw without this.
  const bytes = new TextEncoder().encode(payload);
  const binary = Array.from(bytes, (b) => String.fromCharCode(b)).join("");
  return "MSPK1-" + btoa(binary);
}

export function inviteURL(code: string) {
  const origin = typeof window === "undefined" ? "" : window.location.origin;
  return `${origin}/join/${code}`;
}
