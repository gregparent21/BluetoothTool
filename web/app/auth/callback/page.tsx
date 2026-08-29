"use client";

import { Suspense, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { supabase } from "@/lib/supabase";

function Callback() {
  const router = useRouter();
  const params = useSearchParams();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!supabase) return;

    // Google reports a refusal in the URL rather than by failing the redirect.
    const denied = params.get("error_description") ?? params.get("error");
    if (denied) return setError(denied);

    // Only ever follow a path on this origin — `next` arrives from the URL, so
    // treating it as a full destination would make this an open redirect.
    const raw = params.get("next") ?? "/";
    const next = raw.startsWith("/") && !raw.startsWith("//") ? raw : "/";

    // detectSessionInUrl exchanges the code as the client initialises; that
    // finishes just after this effect runs, so wait for the resulting event
    // rather than reading the session immediately.
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      if (session) router.replace(next);
    });
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) router.replace(next);
    });

    const timeout = setTimeout(
      () => setError("Sign-in didn't complete. Try again."),
      12000,
    );
    return () => {
      sub.subscription.unsubscribe();
      clearTimeout(timeout);
    };
  }, [params, router]);

  if (error) {
    return (
      <main className="centered">
        <div className="banner error">{error}</div>
        <a className="link-btn" href="/">
          Back
        </a>
      </main>
    );
  }
  return <main className="centered">Signing you in…</main>;
}

export default function Page() {
  // useSearchParams needs a Suspense boundary to prerender at build time.
  return (
    <Suspense fallback={<main className="centered">Signing you in…</main>}>
      <Callback />
    </Suspense>
  );
}
