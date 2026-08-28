# Deploying the remote control

This gets the phone-facing page at `web/` live on Vercel, backed by a Supabase
project, and connects your Mac to both. Budget about twenty minutes.

Nothing here affects the menu bar app itself. Multi-Speaker works exactly the
same locally whether or not any of this exists — the remote is strictly
additive, and the app runs local-only if it can't find its config file.

## What you are building

```
iPhone (Vercel)  ──insert command──▶  Supabase  ◀──poll every 750ms──  Mac
       ▲                              Postgres                          │
       └──────── realtime state ──────────┴──── publish state ──────────┘
```

Three moving parts, each with its own credentials:

| Part | Where it runs | Key it holds | Can it be seen by users? |
| --- | --- | --- | --- |
| Postgres + Realtime | Supabase | — | — |
| The page | Vercel (static) | anon / publishable | Yes, by design |
| The agent | Your Mac | service_role / secret | No, never leaves the Mac |

The Mac only makes **outbound** connections, so there is no port to forward and
no static IP to buy. The trade-off is that the Mac must be awake and running
Multi-Speaker for the page to do anything at all.

## Before you start

- A [Supabase](https://supabase.com) account (free tier is plenty).
- A [Vercel](https://vercel.com) account (free Hobby tier is plenty).
- Node 18+ and npm. `node -v` to check.
- This repo pushed to GitHub if you want git-based deploys. It already has an
  `origin`; see [step 6](#6-commit-web-and-supabase) — `web/` and `supabase/`
  may still be untracked.

---

## 1. Create the Supabase project

1. [Dashboard](https://supabase.com/dashboard) → **New project**.
2. Name it anything. **Pick the region closest to your Mac** — every command
   makes a round trip, and a volume nudge across an ocean feels sluggish.
3. Save the database password somewhere. You won't need it for this setup, but
   it is shown once.
4. Wait for provisioning (~2 minutes).

## 2. Create the schema

Open **SQL Editor** → **New query**, paste the entire contents of
[`supabase/schema.sql`](supabase/schema.sql), and run it.

```sh
# to get it into your clipboard
pbcopy < supabase/schema.sql
```

That creates four tables (`rooms`, `speakers`, `playback`, `commands`), adds
`speakers` and `playback` to the realtime publication, turns on RLS with
policies that let the public key read state and queue commands but nothing else,
and finishes by inserting one room.

**The last statement returns a uuid. Copy it now.** That uuid is the room, and
it is the only credential that matters — see [Who can control
it](#who-can-control-it) below.

If you lose it before saving it:

```sql
select id, name, created_at from rooms order by created_at desc limit 5;
```

> **Re-running the file is safe except for that last `insert`,** which mints a
> *new* room every time. If you re-run the whole file, take the newest uuid and
> update both config files, or delete the stray room.

### Verify

In **Table Editor** you should see all four tables, empty. In **Database →
Publications → `supabase_realtime`**, `speakers` and `playback` should both be
listed. If they aren't, realtime push won't work and the page will look frozen
until you reload it.

## 3. Collect the two keys

**Project Settings → API Keys.** Supabase is mid-migration between two key
formats, and you may see either:

| Role | New name | Legacy name | Goes to |
| --- | --- | --- | --- |
| Public | `sb_publishable_...` | `anon` (a JWT starting `eyJ`) | Vercel + `web/.env.local` |
| Secret | `sb_secret_...` | `service_role` (a JWT starting `eyJ`) | Your Mac only |

Either format works — the page passes its key to `supabase-js`, and the Mac
sends its key as the `apikey` and `Authorization` headers to PostgREST. Both
accept old and new styles.

### The Project URL

It always has the form `https://<project-ref>.supabase.co`, and there are three
places to get it:

- **The `Connect` button** at the top of the dashboard — shows the URL and the
  keys together, already formatted for `supabase-js`. Easiest.
- **Project Settings → Data API → Project URL.** The keys moved to their own
  **API Keys** page, so the URL is no longer beside them.
- **Your browser's address bar.** While the project is open you are at
  `supabase.com/dashboard/project/<project-ref>` — that middle segment *is* the
  ref, so the URL is `https://<that>.supabase.co`. Works regardless of how the
  dashboard is laid out this month.

The ref is roughly twenty lowercase letters. It is not a secret; it appears in
every request the browser makes.

> The secret key bypasses RLS entirely. It belongs in
> `~/.config/multi-speaker/remote.json` and nowhere else — never in Vercel,
> never in this repo, never in a `NEXT_PUBLIC_` variable.

## 4. Point your Mac at it

Create the config file the app reads at launch:

```sh
mkdir -p ~/.config/multi-speaker
cat > ~/.config/multi-speaker/remote.json <<'EOF'
{
  "supabaseURL": "https://xxxxxxxxxxxx.supabase.co",
  "serviceKey": "<secret / service_role key>",
  "roomID": "<the uuid from step 2>",
  "roomName": "House"
}
EOF
chmod 600 ~/.config/multi-speaker/remote.json
```

Then rebuild and restart:

```sh
./build.sh && open build/BluetoothTool.app
```

Click the menu bar icon. An **antenna icon** appears in the header — blue when
the relay is healthy, orange with the reason on hover when it isn't. Hovering an
orange antenna is the fastest diagnostic you have; it shows the actual HTTP
status Supabase returned.

The first time the app reads Spotify, macOS asks for **Automation** permission.
Say yes, or now-playing and the transport buttons stay dead on the website.

### Verify

Back in the Supabase **Table Editor**, `speakers` should now have a row per
paired device and `playback` one row, both stamped with your room id. If they're
empty, the Mac isn't publishing — check the antenna.

## 5. Run the website locally first

Do this before deploying. A local run rules out bad keys, and it is much faster
to iterate on than a Vercel build.

```sh
cd web
cp .env.local.example .env.local
```

Fill in all three (`.env.local` is gitignored):

```sh
NEXT_PUBLIC_SUPABASE_URL=https://xxxxxxxxxxxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<publishable / anon key>
NEXT_PUBLIC_ROOM_ID=<the uuid from step 2>
```

```sh
npm install
npm run dev
```

Open http://localhost:3000 on your Mac, and on your phone at
`http://<your-mac's-lan-ip>:3000`. You should see your speakers with live
volume sliders. Drag one — the real speaker should move within a second.

If the page says "Not configured yet", one of the three variables is missing;
the page checks for all three before it builds a client.

## 6. Commit `web/` and `supabase/`

Vercel's git integration needs these tracked. Confirm nothing secret is going
along for the ride:

```sh
git status --short
git check-ignore -v web/.env.local   # must print a match
```

```sh
git add web supabase DEPLOY.md
git commit -m "Add remote control website and Supabase schema"
git push
```

`web/.gitignore` already excludes `node_modules/`, `.next/`, `.env.local`, and
`.vercel`. If `git status` shows `web/.env.local`, **stop** and fix that before
pushing.

## 7. Deploy to Vercel

### The dashboard route (recommended)

1. [vercel.com/new](https://vercel.com/new) → import `gregparent21/BluetoothTool`.
2. **Root Directory → Edit → `web`.** This is the step everyone misses. The repo
   root is a Swift package; point Vercel at it and the build fails with "no
   Next.js version detected".
3. Framework Preset should auto-detect as **Next.js**. Leave the build and
   output settings alone.
4. Expand **Environment Variables** and add the same three from `.env.local`.
   Apply them to Production, Preview, and Development.
5. **Deploy.** First build takes a minute or two.

### The CLI route

```sh
npm i -g vercel
cd web
vercel                    # answer "yes" to link, accept the detected settings
vercel env add NEXT_PUBLIC_SUPABASE_URL production
vercel env add NEXT_PUBLIC_SUPABASE_ANON_KEY production
vercel env add NEXT_PUBLIC_ROOM_ID production
vercel --prod
```

Running `vercel` from inside `web/` makes that the project root automatically,
so there is no Root Directory setting to get wrong.

> **`NEXT_PUBLIC_*` variables are baked in at build time.** The page compiles to
> static HTML — there is no server reading env vars at request time. Changing
> any of the three in the Vercel dashboard does nothing until you **redeploy**
> (Deployments → ⋯ → Redeploy). This is the single most common "I updated it and
> nothing happened" here.

### Verify

Open the deployment URL on your phone over cellular, with Wi-Fi off. That proves
the whole path — phone → Vercel → Supabase → your Mac — without your LAN quietly
covering for a misconfiguration.

Add it to your home screen: the app is configured as a standalone web app
(`appleWebApp` in `layout.tsx`), so it opens without Safari chrome.

---

## Who can control it

**The room id in the URL is the password.** Anyone with the link has full
control of your speakers and your Spotify while the Mac is running. Links can be
forwarded, and there is no way to revoke one person.

To cut everyone off, mint a new room and update both config files:

```sql
insert into rooms (name) values ('House') returning id;
```

Then put the new uuid in `~/.config/multi-speaker/remote.json` and in Vercel's
`NEXT_PUBLIC_ROOM_ID` — **and redeploy**. Optionally delete the old room, which
cascades away its speakers, playback, and queued commands:

```sql
delete from rooms where id = '<old uuid>';
```

The publishable key in the page is public by design; RLS confines it to reading
state and inserting commands. It cannot list rooms or discover room ids, so a
stranger with the key but not the uuid can do nothing.

That trade is right for a party and wrong for anything that matters. If you ever
need real access control, put Supabase Auth in front of it and key the policies
on `auth.uid()` instead of `using (true)`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Vercel: "No Next.js version detected" | Root Directory is the repo root | Set it to `web`, redeploy |
| Page shows "Not configured yet" | A `NEXT_PUBLIC_*` var is missing or blank | Add all three, **redeploy** |
| Page loads but is empty | Room id mismatch between Mac and web, or the Mac isn't publishing | Compare both against `select id from rooms`; check the antenna |
| Sliders move, speakers don't | Mac agent isn't draining commands | Hover the antenna; rows in `commands` with a null `consumed_at` and growing means the poll is failing |
| State never updates until reload | Realtime not publishing | Database → Publications → add `speakers` and `playback` |
| Orange antenna, "rejected the key (HTTP 401)" | Wrong or truncated service key in `remote.json` | Re-copy from Project Settings → API Keys |
| Orange antenna, HTTP 404 | Schema never ran, or wrong project URL | Re-run `schema.sql`; check the URL |
| Now-playing blank, transport dead | Automation permission denied | System Settings → Privacy & Security → Automation → allow Multi-Speaker → Spotify |
| Everything dead after a week away | Free Supabase projects pause after 7 days idle | Dashboard → Restore project |

A useful check when the site looks stuck — this is exactly what the Mac polls:

```sql
select id, kind, address, value, created_at, consumed_at
  from commands order by id desc limit 20;
```

Rows appearing with `consumed_at` filled in a second later means the whole loop
is healthy and the problem is elsewhere.

## Running costs

Zero, at this scale. The page is static, so Vercel serves it from cache; the
only Supabase traffic is a small poll every 750ms while your Mac is awake, plus
one realtime connection per phone. Both free tiers absorb that comfortably.

The one thing to watch is the free-tier pause: seven days without activity and
Supabase suspends the project, which you restore in one click from the
dashboard. Leaving the Mac app running keeps it warm.

## Updating

The website redeploys on every push to `main` that touches `web/`. Nothing else
needs doing.

Schema changes are manual — paste the new SQL into the SQL editor. If you re-run
all of `schema.sql`, remember the trailing `insert` mints a new room.

The Mac app updates with `./build.sh`, and re-reads `remote.json` at launch, so
credential changes need a restart.
