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

`web/` is a Next.js site where each person signs in with Google, creates a
**house**, and gets a link they can send to friends so everyone can control the
speakers from their phone.

It is a **remote control, not an audio path**. The music still plays from the
Mac, and that Mac has to be awake and running Multi-Speaker for the page to do
anything.

```
Friend's phone ─┐
                │  Google sign-in, one house each
 Your phone ────┼───────────▶  Vercel  ──▶  Supabase (Postgres + Auth)
                │                                    ▲
                └────────────────────────────────────┤ publish state,
                                                     │ drain commands
                                          Your Mac ──┘ (polled, 750ms)
```

Commands go one way and state comes back the other; nothing needs an inbound
port or a static IP, because the Mac only ever makes outbound connections.

### Setting it up

One person deploys the backend once — [`DEPLOY.md`](DEPLOY.md) covers Supabase,
Google OAuth, and Vercel end to end. After that, each new person:

1. Opens the site and signs in with Google.
2. Creates a house, and follows the setup page.
3. **Picks one computer for the house.** Every speaker pairs to that Mac, and
   that Mac is what plays the music — so it should be the one that lives where
   the speakers are and stays plugged in.
4. Runs `./build.sh` on it, then pastes the setup code from the website into the
   menu bar app under **Set up remote…**.
5. Sends the invite link to whoever should be able to change the music.

No file editing, no keys to copy by hand, and nothing shared between houses.

### Who can control it

Access is per house and tied to a real account:

- **Following an invite link requires signing in**, and adds that account to the
  house. Forwarding a link lets someone else join; it does not hand over a
  session.
- **The owner can rotate the link**, which kills every link handed out so far
  while leaving current members in place.
- **Members can control the speakers and nothing else** — they cannot read the
  command queue, see the house's devices, or learn that other houses exist.

Each Mac authenticates with a **device token** scoped to one house, revocable
from the website. Earlier versions put a Supabase `service_role` key on the Mac,
which was defensible when you ran your own backend and is not once one backend
serves several people. Nothing outside Supabase holds that key now.

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
| `Sources/BluetoothTool/RemoteConfig.swift` | Device credentials, and the setup-code format |
| `supabase/schema.sql` | Tables, accounts, RLS, and the agent's two RPCs |
| `web/` | Next.js site: sign-in, houses, invites, controls |
| `DEPLOY.md` | Supabase + Google OAuth + Vercel deployment guide |
| `Tools/SelfTest.swift` | Hardware self-test |
