"use client";

import { useEffect, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { db, isConfigured } from "@/lib/supabase";
import { useSession } from "@/lib/useSession";
import { SignInPanel } from "@/components/SignIn";
import { NotConfigured } from "@/components/NotConfigured";

/// The other end of a shared link. Signing in and joining are one step from the
/// guest's point of view: they land here, tap once, and are in the house.
export default function JoinPage() {
  const { code } = useParams<{ code: string }>();
  const { user, loading } = useSession();
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  // Google can fire the auth event more than once; joining twice is harmless
  // but the redirect race it causes is not.
  const attempted = useRef(false);

  useEffect(() => {
    if (!user || attempted.current) return;
    attempted.current = true;
    (async () => {
      const { data, error } = await db().rpc("join_house", { p_code: code });
      if (error) return setError(error.message);
      router.replace(`/house/${data.id}`);
    })();
  }, [user, code, router]);

  if (!isConfigured) return <NotConfigured />;
  if (loading) return <main className="centered">Loading…</main>;

  if (!user) {
    return (
      <SignInPanel
        next={`/join/${code}`}
        heading="Sign in to join"
        blurb="Someone shared their speakers with you. Sign in and you can control what plays."
      />
    );
  }

  if (error) {
    return (
      <main className="centered">
        <div className="banner error">{error}</div>
        <p className="fine">
          Invite links stop working when the host makes a new one. Ask them to
          send the current link.
        </p>
        <a className="link-btn" href="/">
          Your houses
        </a>
      </main>
    );
  }

  return <main className="centered">Joining…</main>;
}
