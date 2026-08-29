"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { db, isConfigured, type Membership } from "@/lib/supabase";
import { useSession, signOut } from "@/lib/useSession";
import { SignInPanel } from "@/components/SignIn";
import { NotConfigured } from "@/components/NotConfigured";

export default function Home() {
  const { user, loading } = useSession();
  const [houses, setHouses] = useState<Membership[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await db()
      .from("house_members")
      .select("role, houses(*)")
      .order("joined_at", { ascending: true });
    if (error) setError(error.message);
    // PostgREST types the embedded row as an array; it is a to-one join.
    else setHouses((data ?? []) as unknown as Membership[]);
    setLoaded(true);
  }, []);

  useEffect(() => {
    if (user) load();
  }, [user, load]);

  async function createHouse(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim()) return;
    setCreating(true);
    setError(null);
    const { error } = await db().rpc("create_house", { p_name: name.trim() });
    setCreating(false);
    if (error) return setError(error.message);
    setName("");
    load();
  }

  if (!isConfigured) return <NotConfigured />;
  if (loading) return <main className="centered">Loading…</main>;
  if (!user) return <SignInPanel next="/" />;

  const owned = houses.filter((h) => h.role === "owner");

  return (
    <main>
      <div className="topbar">
        <h1>Your houses</h1>
        <button className="link-btn" onClick={signOut}>
          Sign out
        </button>
      </div>
      <p className="sub">{user.email}</p>

      {error && <div className="banner error">{error}</div>}

      {loaded && houses.length === 0 && (
        <div className="banner">
          You aren&rsquo;t in any house yet. Make one for your place below, or
          open the link a friend sent you.
        </div>
      )}

      {houses.map(({ role, houses: house }) => (
        <Link key={house.id} href={`/house/${house.id}`} className="house-row">
          <div>
            <div className="name">{house.name}</div>
            <div className="status">{role === "owner" ? "You host this" : "Shared with you"}</div>
          </div>
          <span className="chev">›</span>
        </Link>
      ))}

      <form className="new-house" onSubmit={createHouse}>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="New house name, e.g. Greg's Place"
          maxLength={60}
          aria-label="New house name"
        />
        <button disabled={creating || !name.trim()}>{creating ? "…" : "Create"}</button>
      </form>

      {owned.length === 0 && (
        <p className="fine">
          A house is one computer with your speakers paired to it. Create one and
          you&rsquo;ll get step-by-step setup instructions for that computer.
        </p>
      )}
    </main>
  );
}
