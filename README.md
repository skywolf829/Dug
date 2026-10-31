# Dug 🐿️

A talking collar for a Halloween *Up* costume. The dog wears the collar, and the humans trigger
clips from their phones.

```
┌──────────────┐   BLE    ┌───────────────────────────┐
│ iPhone app   │ ───────▶ │ ItsyBitsy nRF52840        │
│  soundboard  │          │  2 MB flash (clips)       │──I2S──▶ MAX98357A ──▶ 🔊
│  mp3 → μ-law │ ◀─────── │  BLE: play / upload       │
└──────────────┘  status  └───────────────────────────┘
   (×2 phones)
```

- **`ios/`**: SwiftUI soundboard app. Clips are decoded, resampled to 16 kHz, run through a loudness
  chain, compressed to μ-law, and uploaded to the collar. A built-in **simulated collar** runs the
  same protocol and plays through the phone, so the whole app works before the hardware does.
- **`firmware/DugCollar/`**: Arduino sketch. Stores clips on QSPI flash (LittleFS) and plays them
  through I2S DMA. Two phones can connect at once.
- **`docs/`**: [protocol](docs/PROTOCOL.md) and [wiring](docs/WIRING.md).

## Clips

The audio isn't in this repo. Put your mp3s in `ios/LocalClips/` (git-ignored) before building; the
build copies them into the app. `ios/Dug/Model/Phrase.swift` lists the filenames and button labels.

## iOS app

Requires Xcode 15+ (iOS 17+ target) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd ios && xcodegen && open Dug.xcodeproj
```

1. In the Dug target → Signing & Capabilities, pick your team (a free Apple ID works) and change the
   bundle id to something unique (`com.yourname.dug`).
2. Plug in a phone and run. With a free Apple ID the install expires after 7 days, so reinstall the
   week of Halloween.
3. The app starts in **Simulator** mode. Switch to **Real collar** in Settings once the hardware is built.

Long-press a button to preview it on the phone, or hold and drag to reorder.

## Firmware

Arduino IDE or `arduino-cli`:

```sh
arduino-cli config add board_manager.additional_urls \
  https://adafruit.github.io/arduino-board-index/package_adafruit_index.json
arduino-cli core update-index && arduino-cli core install adafruit:nrf52
arduino-cli lib install "Adafruit SPIFlash" "SdFat - Adafruit Fork"

arduino-cli compile --fqbn adafruit:nrf52:itsybitsy52840 firmware/DugCollar
arduino-cli upload  --fqbn adafruit:nrf52:itsybitsy52840 -p /dev/cu.usbmodem* firmware/DugCollar
```

The first boot formats the 2 MB flash (this erases CircuitPython files, if there were any). Clips arrive from
the app: when it connects, it "teaches" the collar every clip.

## Status

- [x] Firmware compiles (Adafruit nRF52 core 1.7.0). **Not yet tested on hardware.**
- [x] iOS app type-checks against the iOS 17 SDK. Simulator mode exercises the full protocol.
- [ ] First hardware bring-up: check I2S audio, volume, and BLE upload speed
- [ ] Ideas: App Intent so the iPhone Action button yells "Squirrel!", and a Lock Screen widget
