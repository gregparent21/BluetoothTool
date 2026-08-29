"use client";

import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import type { Session } from "@supabase/supabase-js";

/**
 * The signed-in session, or null. `loading` is true until Supabase has read
 * whatever it has in storage — every page needs that distinction, because
 * "signed out" and "not known yet" want very different UI.
 */
export function useSession() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!supabase) {
      setLoading(false);
      return;
    }
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
      setLoading(false);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  return { session, user: session?.user ?? null, loading };
}

/// Send the browser to Google and come back to `next` (a path on this origin).
export async function signInWithGoogle(next?: string) {
  if (!supabase) return;
  const origin = window.location.origin;
  const target = next ?? window.location.pathname + window.location.search;
  await supabase.auth.signInWithOAuth({
    provider: "google",
    options: {
      redirectTo: `${origin}/auth/callback?next=${encodeURIComponent(target)}`,
    },
  });
}

export async function signOut() {
  await supabase?.auth.signOut();
}
