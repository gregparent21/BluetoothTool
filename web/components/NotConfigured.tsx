/// Shown when the deployment is missing its Supabase keys. Without this the
/// whole app would fail on a null client, which reads as "the site is broken"
/// rather than "the site needs two environment variables".
export function NotConfigured() {
  return (
    <main>
      <h1>Multi-Speaker</h1>
      <div className="banner">
        Not configured yet. Set <code>NEXT_PUBLIC_SUPABASE_URL</code> and{" "}
        <code>NEXT_PUBLIC_SUPABASE_ANON_KEY</code> — locally in{" "}
        <code>web/.env.local</code>, or in your Vercel project settings — then
        redeploy. See <code>DEPLOY.md</code>.
      </div>
    </main>
  );
}
