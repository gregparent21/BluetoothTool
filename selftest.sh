#!/bin/bash
# Runs the hardware self-test. Pass --connect to also wake disconnected speakers.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d)/selftest"
swiftc -parse-as-library -swift-version 5 \
    Sources/BluetoothTool/CoreAudioSupport.swift \
    Sources/BluetoothTool/AudioDevices.swift \
    Sources/BluetoothTool/MultiOutputDevice.swift \
    Sources/BluetoothTool/BluetoothDevices.swift \
    Tools/SelfTest.swift -o "$OUT"
"$OUT" "$@"
