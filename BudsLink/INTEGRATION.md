# BudsLinkEarbuds: drop-in earbud detection, battery, capability layer

**Status: written without a Swift compiler and never run on hardware. Build it, fix any
compile errors (paste them to me), and run the checklist below before trusting it.**

Five new files, zero edits to existing files. Nothing here calls `setCategory`, `setActive`,
`setPreferredInput`, `AVAudioEngine`, or requests the microphone, so `LiveListenManager`,
`AudioManager` and `ConnectionMonitor` are untouched. The only audio-session access is a
read of `currentRoute`.

## Wire-up (about 6 lines)

1. Add the five `.swift` files to the BudsLink target.
2. In `BudsLinkApp`, add `@StateObject private var hub = EarbudHub()`.
3. Add a tab: `EarbudStatusView(hub: hub).tabItem { Label("Earbuds", systemImage: "earbuds") }`.
4. Run it **alongside** the old Dashboard first and compare. Once the new tab is correct,
   stop using `BluetoothManager.state` / `isTarget` for the connected indicator.

No Info.plist change is needed (`NSBluetoothAlwaysUsageDescription` already exists).
Optional: add `bluetooth-central` to `UIBackgroundModes` if you want battery/link updates while
the app is backgrounded. Today only `audio` is declared, so BLE callbacks pause in the background.

## What decides each state

| UI element | Real evidence used |
|---|---|
| Connected / Disconnected | System audio route is Bluetooth (A2DP/HFP/LE) **or** GATT link established |
| Device name | Audio-route port name, else peripheral name |
| Battery rows | GATT Battery Service `0x180F` / Battery Level `0x2A19` (read + notify) |
| Left / Right / Case labels | Device's own labels only: User Description `0x2901`, or SIG namespace `0x010D`/`0x010E` in Presentation Format `0x2904`. Otherwise shown unlabeled. Never guessed. |
| Charging bolt | Battery Power State `0x2A1A` |
| Firmware / model | Device Information `0x180A` (`0x2A26`, `0x2A24`, `0x2A29`, ...) |
| Noise Control | `NoiseControlProvider` registry. **Empty by default**, so it truthfully says "not exposed". |

## Enabling Noise Control for a specific model

1. Run the app with the earbuds connected, open **Bluetooth Report**, and share it.
2. If the report shows a vendor service with a writable characteristic **and** you have the
   vendor's documentation for it, implement `NoiseControlProvider` for that layout and return it
   from `NoiseControlRegistry.providers()`.
3. If the report shows only `1800`/`1801`/`180A`/`180F` (typical), the earbuds do not expose ANC
   over BLE. iOS has no public ANC API and Classic-Bluetooth/RFCOMM vendor protocols are not
   reachable from third-party apps without MFi. Nothing legitimate can be added.

## Hardware test checklist (not yet run)

1. Connect earbuds, then screen shows **Connected** with the right name within a couple of seconds.
2. Battery shows real values, **or** "Battery information is not exposed by this device."
3. Disconnect earbuds (or put them in the case), then **Disconnected**; reconnect gives **Connected**
   without restarting the app.
4. Toggle Bluetooth off/on and deny/allow permission; each state shows the right message.
5. **Live Listen:** start it, confirm audio works, open the new tab, switch tabs, connect/disconnect
   earbuds. Behavior must match the old build exactly.
6. If a noise-control provider was added: change mode in-app and confirm the physical earbuds change.
