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
5. **Stop** puts your audio output back where it was and removes the device.

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
- **Speakers in the same room will echo.** Different models have very different
  output latency (earbuds are typically much faster than a portable speaker), and
  a stacked device does not delay-compensate. Across separate rooms or headphones
  it doesn't matter.
- **Volume control needs AVRCP absolute volume.** Nearly all modern devices have
  it. Anything that doesn't shows "no volume control" and a dead slider —
  software gain would need a virtual audio driver, which this deliberately avoids.
- **Connecting a powered-off speaker times out** after ~10s. The app says so.

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
| `Tools/SelfTest.swift` | Hardware self-test |
