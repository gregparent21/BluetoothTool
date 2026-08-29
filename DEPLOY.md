# Deploying Multi-Speaker

This walks you through standing up the hosted service: a Supabase project for
accounts and state, and a Vercel deployment for the website. **You do this
once.** After that, anyone you point at the site signs in with Google, creates
their own house, and sets up their own computer — none of them touch Supabase or
Vercel, and none of them can see each other's speakers.

Budget about 30 minutes. Everything here fits inside the free tiers.

## What you are building

```
   Friend's phone ─┐
                   │  sign in with Google, control one house
   Your phone ─────┼──────────▶  Vercel (Next.js)
                   │                   │
                   │                   ▼
                   └──────────▶  Supabase (Postgres + Auth)
                                       ▲
                                       │  publish state, drain commands
                                       │  (device token, polled every 750ms)
                                       │
                       ┌───────────────┴───────────────┐
                       │                               │
              Your Mac, your house          Their Mac, their house
              speakers paired to it         speakers paired to it
```

Two things are worth understanding before you start.

**The music never touches the website.** Each house has one computer with the
speakers paired to it, and that computer is what plays. The site only queues
instructions for it. A phone with the page open and the Mac asleep does nothing.

**No user's Mac holds a privileged key.** Each Mac gets a *device token* that
the database resolves to exactly one house. It can publish that house's speaker
state and drain that house's command queue, and there is no third thing it can
do. This is what makes it safe to run one backend for a dozen friends.

## Before you start

You need:

- A GitHub account (Vercel signs in with it).
- A Google account, for the OAuth credentials.
- This repository pushed somewhere Vercel can see it.
- Node 18+ locally, if you want to test the site before deploying.

---

## 1. Create the Supabase project

1. Go to [supabase.com](https://supabase.com), sign in, **New project**.
2. Name it whatever you like. Pick a region near you — this is where the command
   latency comes from.
3. Set a database password and save it somewhere. You won't need it for this
   guide, but you cannot see it again.
4. Wait for provisioning, ~2 minutes.

## 2. Create the schema

Open **SQL Editor → New query**, paste in the whole of
[`supabase/schema.sql`](supabase/schema.sql), and run it.

```sh
pbcopy < supabase/schema.sql   # to get it into your clipboard
```

It creates the tables, the row-level security policies, and the functions the
website and the Mac agents call. It is safe to run again later.

> **Upgrading from the single-house version?** The script detects the old
> schema and drops it. You lose nothing that matters — the speaker and playback
> rows are a cache that each Mac republishes within two seconds of starting. You
> will need to re-do step 5 on each Mac, because the old `remote.json` used a
> `service_role` key and that is no longer how agents authenticate.

### Verify

**Table Editor** should list `houses`, `house_members`, `devices`, `speakers`,
`playback`, and `commands`, all empty. Under **Database → Functions** you should
see `create_house`, `join_house`, `agent_publish`, and `agent_poll` among
others.

## 3. Turn on Google sign-in

This is the only fiddly part, and it's fiddly in a well-documented way.

### 3a. Get your Supabase callback URL

In Supabase, go to **Authentication → Sign In / Providers → Google**. Copy the
**Callback URL** it shows you. It looks like:

```
https://xxxxxxxxxxxx.supabase.co/auth/v1/callback
```

### 3b. Make Google credentials

1. Open the [Google Cloud Console](https://console.cloud.google.com), create a
   project (or reuse one).
2. **APIs & Services → OAuth consent screen.** Choose **External**. Fill in an
   app name, your email for both support and developer contact, and save.
   - Leave it in **Testing** mode only if you're the only user — testing mode
     caps you at 100 hand-listed test users. To let any friend sign in, hit
     **Publish app**. A basic app requesting only email and profile is not
     subject to Google's verification review.
3. **APIs & Services → Credentials → Create credentials → OAuth client ID.**
   - Application type: **Web application**.
   - Under **Authorised redirect URIs**, add the Supabase callback URL from 3a.
   - Create, then copy the **Client ID** and **Client secret**.

### 3c. Paste them into Supabase

Back in **Authentication → Providers → Google**: enable it, paste the client ID
and secret, save.

### 3d. Set the redirect allowlist

**Authentication → URL Configuration.** This decides where Supabase is willing
to send someone after sign-in, so getting it wrong is the single most common
reason for a "requested path is invalid" error.

- **Site URL**: your Vercel URL (e.g. `https://multi-speaker.vercel.app`). You
  won't have this until step 7 — set it to `http://localhost:3000` for now and
  come back.
- **Redirect URLs**: add both, one per line.

  ```
  http://localhost:3000/**
  https://your-project.vercel.app/**
  ```

## 4. Collect the two keys

**Project Settings → API Keys.** You need exactly two values, and neither is
secret:

| Value | Where it goes |
| --- | --- |
| **Project URL** — `https://xxxx.supabase.co` | `NEXT_PUBLIC_SUPABASE_URL` |
| **anon / publishable key** | `NEXT_PUBLIC_SUPABASE_ANON_KEY` |

The anon key ships inside the website and is meant to be public. It grants
nothing on its own: every policy in the schema keys on the signed-in user, so
without a session it can read and write nothing at all.

**Do not copy the `service_role` key.** Nothing in this project uses it. If you
find yourself pasting it somewhere, something has gone wrong.

## 5. Run the website locally first

Prove it works before involving Vercel.

```sh
cd web
cp .env.local.example .env.local     # fill in the two values from step 4
npm install
npm run dev
```

Open <http://localhost:3000>.

### Verify

1. You get the landing page with a **Continue with Google** button.
2. Signing in returns you to the site with your email shown.
3. Create a house. It appears in the list, and opening it says no computer is
   set up yet.
4. Open **Set up →** and press **Make a setup code**. You get a long
   `MSPK1-…` blob.

If sign-in bounces back to the landing page, it's almost always step 3d —
`http://localhost:3000/**` has to be in the redirect allowlist.

## 6. Connect your Mac

On the Mac with the speakers (see [Picking the computer](#picking-the-computer)
below):

```sh
./build.sh
open build/BluetoothTool.app
```

Click the menu bar speaker icon → **Set up remote…** → **Paste** →
**Connect**.

### Verify

- The panel switches to showing your house name with a blue antenna.
- The website's setup page now says the computer checked in *just now*.
- The house page lists your paired speakers, and moving a slider on the phone
  moves the speaker.

The first time the app reads Spotify, macOS asks for Automation permission. Say
yes, or now-playing and the transport buttons stay dead.

## 7. Deploy to Vercel

1. [vercel.com](https://vercel.com) → **Add New → Project** → import the repo.
2. **Root Directory: `web`.** This is the one setting people miss; without it
   the build fails looking for a `package.json` at the repo root.
3. Add the two environment variables from step 4.
4. Deploy.

Then go back to **Supabase → Authentication → URL Configuration** and set the
Site URL and redirect allowlist to the real Vercel URL (step 3d).

### Verify

Open the deployed URL on your phone, sign in, and confirm your house and
speakers are there. Then send the invite link to someone else and watch them
join — that's the whole product working end to end.

---

## Picking the computer

Worth being deliberate about, because it's the constraint everything else
inherits:

- **It has to stay awake.** Sleep kills Bluetooth audio and the agent stops
  checking in. Either leave it plugged in with sleep set to Never in
  **System Settings → Battery/Lock Screen**, or accept that the house goes quiet
  when the lid closes.
- **Bluetooth range is the limit, not wifi.** Put it near the middle of the
  speakers, not near the router.
- **Every speaker pairs to this one machine.** Nothing pairs to a phone.
- **Two or three speakers is the practical ceiling.** They share one radio and
  macOS drops to a lower-bandwidth codec as you add devices.

## Who can control what

| | Sees the house | Controls speakers | Invite link | Sets up a Mac |
| --- | --- | --- | --- | --- |
| Owner | ✅ | ✅ | ✅ can rotate | ✅ |
| Invited member | ✅ | ✅ | — | — |
| Anyone else | — | — | — | — |

Some specifics that follow from the schema rather than from the UI:

- **A link is an invitation, not a key.** Following it requires a Google
  sign-in, and it adds *that account* to the house. Forwarding the link lets
  someone else join; it does not hand over an existing session.
- **Rotating the invite link revokes every link handed out so far** and leaves
  everyone who already joined in place. Use it when a link has travelled further
  than you meant.
- **Members cannot read the command queue**, list devices, see other houses, or
  discover that other houses exist.
- **Revoking a device** stops that Mac immediately; the next poll fails and the
  app says so in its menu.

The one thing the model does *not* give you is protection from a member you
invited: anyone in the house can change the volume, skip a track, or turn the
output off. That's the intended behaviour for a party, and it's why the invite
link is worth treating as a real decision.

## Troubleshooting

**Sign-in redirects to a "requested path is invalid" page.**
Step 3d. The exact origin you're browsing from must be in the redirect
allowlist, wildcard included.

**Sign-in works but the house list is empty after creating one.**
Check the browser console for a policy error. Almost always means `schema.sql`
was partially applied — re-run the whole file.

**The page says the computer hasn't checked in.**
The Mac is asleep, the app was quit, or the device was revoked. Open the menu
bar app: a blue antenna means healthy, orange shows the reason on hover.

**"This Mac has been disconnected from its house."**
Its device token was revoked from the setup page. Make a new setup code and
paste it in.

**Album art doesn't load.**
`next.config.mjs` only allows `i.scdn.co`. Nothing else is affected.

**Commands are slow.**
The Mac polls every 750ms and a round trip adds the rest. Sub-second is normal;
multi-second usually means a Supabase region far from the house.

## Running costs

Free, for this shape of use. Supabase's free tier covers the database, auth, and
realtime; Vercel's covers a hobby deployment. The traffic is a handful of small
writes per second per active house.

The one thing to watch is Supabase pausing a project after a week with no
activity. A house that's used occasionally keeps it awake on its own.

## Updating

The website redeploys when you push. The Mac app needs a rebuild:

```sh
./build.sh && open build/BluetoothTool.app
```

Schema changes re-run in the SQL editor. `schema.sql` is written to be
re-runnable, so pasting the whole file again is the intended way to apply it.
