# Multi-Speaker

A macOS menu bar app that plays one audio stream to several Bluetooth speakers
at once, with an independent volume slider for each.

It creates a **Multi-Speaker** output device that shows up everywhere macOS
lists audio outputs, so Spotify and everything else can play to it.

## Requirements

macOS 14+. No Xcode needed — Swift command line tools are enough. No driver
install, no `sudo`, no kernel extension.

## Build and run

```sh
./build.sh
open build/BluetoothTool.app
```

The app has no Dock icon; look for the speaker glyph in the menu bar.

## How to use it

1. Click the menu bar icon. Every paired Bluetooth speaker or headphone is listed.
2. Tick the ones you want to play to. Hit **Connect** on any that are powered off
   and idle (or just power them on — the app connects them for you when you start).
3. Click **Play to N speakers**. That builds the output device and makes it the
   system default, so Spotify follows immediately.
4. Drag each device's slider to set its volume independently.
5. If speakers in the same room echo, nudge the **delay** arrows on the ones that
   sound early until they line up with the slowest speaker. 5 ms per press.
6. **Stop** puts your audio output back where it was and removes the device.

Your speaker selection is remembered between launches.

## How it works

macOS can already fan one stream out to several outputs — that's the "Multi-Output
Device" in Audio MIDI Setup. It just has no volume control and no UI worth using.

This app builds that device programmatically via
`AudioHardwareCreateAggregateDevice` (stacked, non-private so other apps can see
it), picks a stable clock source, and turns on high-quality drift correction for
the others — Bluetooth devices each run their own clock, and without correction
they slowly slide out of sync.

Per-device volume then works because each Bluetooth device is still an
independent CoreAudio object inside the stack. The app writes
`kAudioDevicePropertyVolumeScalar` straight to it, which travels to the speaker
as an AVRCP absolute-volume command. Devices differ in how they expose this:
built-in speakers have one "main" element, AirPods have none but expose one
element per channel, so the app probes for what's actually settable.

Per-speaker delay rides on the same mechanism. Each sub-device in the stack
accepts a `latency-out` value in *sample frames*, so a millisecond figure is
converted using that device's own sample rate. The matching runtime property,
`kAudioSubDevicePropertyExtraLatency`, is not implemented on these sub-devices —
reading it returns `'who?'` — so the value has to be baked in at creation, which
is why a delay change rebuilds the device.

Bluetooth devices only exist as CoreAudio devices while connected, so the app
watches `kAudioHardwarePropertyDevices` and rebuilds the stack as speakers come
and go. The join between IOBluetooth and CoreAudio is the MAC address: a
Bluetooth output device's UID is its address, e.g. `70-8C-F2-E5-AB-AC:output`.

The output device is owned by this process. It disappears when the app quits.

## Known limits

These are properties of Bluetooth audio on macOS, not bugs in the app:

- **Two or three speakers is the practical ceiling.** They share one radio, and
  macOS drops to a lower-bandwidth codec as you add devices. Audio quality falls
  and dropouts get more likely with each one.
- **Speakers in the same room echo until you align them.** Different models have
  very different output latency (earbuds are typically much faster than a
  portable speaker), and a stacked device does no alignment on its own. The
  per-speaker delay control fixes this, but it is a manual calibration by ear —
  macOS does not report a speaker's true output latency, so there is nothing to
  measure against. Once set, it persists.
- **Changing a delay interrupts playback for a moment.** `latency-out` is only
  read when the aggregate is built, so a new value means rebuilding it. Presses
  are coalesced, so a burst of arrow taps costs one rebuild rather than ten.
- **Volume control needs AVRCP absolute volume.** Nearly all modern devices have
  it. Anything that doesn't shows "no volume control" and a dead slider —
  software gain would need a virtual audio driver, which this deliberately avoids.
- **Connecting a powered-off speaker times out** after ~10s. The app says so.

## Remote control from a phone

`web/` is a Next.js page your friends can open on their phones to control the
speakers and Spotify. It is a **remote control, not an audio path** — the music
still plays from this Mac, and the Mac has to be awake and running Multi-Speaker
for the page to do anything.

```
iPhone (Vercel)  ──insert command──▶  Supabase  ◀──poll every 750ms──  Mac
       ▲                              Postgres                          │
       └──────── realtime state ──────────┴──── publish state ──────────┘
```

Commands go one way and state comes back the other; nothing needs an inbound
port or a static IP, because the Mac only ever makes outbound connections.

### 1. Supabase

Create a project, open the SQL editor, and run [`supabase/schema.sql`](supabase/schema.sql).
The last statement returns a room uuid — keep it.

### 2. The Mac

Create `~/.config/multi-speaker/remote.json`. It is read at launch and never
committed:

```jsonc
{
  "supabaseURL": "https://xxxx.supabase.co",
  "serviceKey": "<service_role key from Settings → API>",
  "roomID": "<the uuid from step 1>",
  "roomName": "House"
}
```

Restart the app. An antenna icon appears in the menu header — blue when the
relay is healthy, orange with the reason on hover when it isn't. Without this
file the app runs exactly as before, local-only.

The first time it reads Spotify, macOS asks for Automation permission. Say yes,
or now-playing and the transport buttons stay dead.

### 3. The website

```sh
cd web
cp .env.local.example .env.local   # fill in URL, anon key, room id
npm install && npm run dev
```

Deploy with `vercel` (or point Vercel at the repo with `web` as the root
directory) and set the same three `NEXT_PUBLIC_*` variables in the project
settings. Send your friends the URL.

[`DEPLOY.md`](DEPLOY.md) walks all of this end to end, with the verification
steps and the mistakes worth avoiding.

### Who can control it

**The room id in the URL is the password.** Anyone with the link has full
control, links can be forwarded, and there is no way to revoke one person — to
cut everyone off, insert a new room and update both config files. The anon key
in the page is public by design and RLS keeps it to reading state and queueing
commands; the `service_role` key stays on your Mac and never reaches the browser.
That trade is right for a party and wrong for anything else — put Supabase Auth
in front of it if you ever need more.

## Self-test

Checks every CoreAudio and Bluetooth path against your actual hardware, and
restores everything it touches (volumes, default output, connections):

```sh
./selftest.sh            # test what's already connected
./selftest.sh --connect  # also wake up disconnected speakers first
```

## Layout

| File | Role |
| --- | --- |
| `Sources/BluetoothTool/CoreAudioSupport.swift` | Property-API wrappers over the CoreAudio HAL |
| `Sources/BluetoothTool/AudioDevices.swift` | Device enumeration, volume, mute, default output |
| `Sources/BluetoothTool/MultiOutputDevice.swift` | Creates and maintains the stacked aggregate device |
| `Sources/BluetoothTool/BluetoothDevices.swift` | Paired-device listing, connect/disconnect |
| `Sources/BluetoothTool/AppModel.swift` | State, polling, orchestration |
| `Sources/BluetoothTool/MenuView.swift` | Menu bar UI |
| `Sources/BluetoothTool/NowPlaying.swift` | Spotify transport and now-playing, over AppleScript |
| `Sources/BluetoothTool/RemoteControl.swift` | Supabase agent: publishes state, drains commands |
| `Sources/BluetoothTool/RemoteConfig.swift` | Loads `~/.config/multi-speaker/remote.json` |
| `supabase/schema.sql` | Tables, realtime, and RLS for the relay |
| `web/` | Next.js remote page for phones |
| `DEPLOY.md` | Supabase + Vercel deployment guide |
| `Tools/SelfTest.swift` | Hardware self-test |
