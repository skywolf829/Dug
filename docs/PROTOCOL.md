# Collar ↔ phone protocol

BLE GATT, collar is the peripheral (advertises as **"Dug's Collar"**), up to two phones connect at once.
Mirrored in `firmware/DugCollar/Protocol.h` and `ios/Dug/Collar/DugProtocol.swift` — change both together.

| | UUID | Properties | Direction |
|---|---|---|---|
| Service | `6E1D0001-D0C0-4B1A-9C55-55505F444F47` | | |
| Control | `6E1D0002-…` | write (with response) | phone → collar |
| Data | `6E1D0003-…` | write without response | phone → collar (upload bytes) |
| Status | `6E1D0004-…` | notify | collar → phone |

All integers are little-endian. Names are UTF-8, at most 40 bytes, not NUL-terminated.

## Audio format

Raw G.711 **μ-law, mono, 16 kHz**, no header — 16 KB per second. The collar's 2 MB flash holds
roughly 1¾ minutes total. Max 30 s per clip.

## Clip slots

| id | use |
|---|---|
| 0 | never used (means "nothing" in `STATE.playing`) |
| 1–31 | built-in presets (fixed ids so both phones agree) |
| 32–254 | user phrases |
| 255 | scratch: "say this now" |

Each clip stores a 32-bit `tag` — a fingerprint of text + voice settings — so the app can tell
whether the collar's copy is current.

## Commands (Control)

| Op | Bytes | |
|---|---|---|
| PLAY | `01 id` | |
| STOP | `02` | |
| SET_VOLUME | `03 vol` | 0–255, collar clamps to its `maxVolume` |
| DELETE | `04 id` | |
| LIST | `05` | → `STATE`, one `CLIP` per clip, `LIST_END` |
| UPLOAD_BEGIN | `10 id size:u32 tag:u32 flags name…` | flags bit0 = play when done |
| UPLOAD_ABORT | `11` | |

## Status (notifications)

| Status | Bytes |
|---|---|
| STATE | `80 vol maxVol playing freeKB:u16` |
| CLIP | `81 id size:u32 tag:u32 name…` |
| LIST_END | `82 00` |
| UPLOAD_ACK | `90 committed:u32` |
| UPLOAD_DONE | `91 id` |
| UPLOAD_ERROR | `92 err` |
| PLAY_STARTED | `A0 id` |
| PLAY_STOPPED | `A1 id` |
| ERROR | `EE err` |

Errors: 1 busy, 2 no such clip, 3 flash full, 4 bad command, 5 overflow, 6 filesystem.

## Upload flow

```
phone                                   collar
  UPLOAD_BEGIN(id, size, tag, flags, name) →
                                        ← UPLOAD_ACK(0)          ready (temp file open)
  Data chunks (≤ MTU-3 bytes each)  →
                                        ← UPLOAD_ACK(n)          every 1 KB written to flash
  …never more than 4096 bytes past the last ACK…
                                        ← UPLOAD_ACK(size)
                                        ← UPLOAD_DONE(id)
                                        ← CLIP(id, …), STATE
                                        ← PLAY_STARTED(id)       if flags bit0
```

- Data received before `UPLOAD_ACK(0)` is dropped.
- The collar buffers incoming data in an 8 KB ring; the 4 KB window keeps it from overflowing.
- An upload stops any playback, and playback is refused while an upload is in progress.
- No data for 5 s → the collar aborts with `UPLOAD_ERROR`. The app gives up after 6 s without an ack.
- A finished upload replaces the slot atomically (written to a temp file, then renamed).
