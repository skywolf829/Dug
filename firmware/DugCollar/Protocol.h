// Wire protocol between the collar and the phone app.
// Mirrors ios/Dug/Collar/DugProtocol.swift — see docs/PROTOCOL.md. Keep them in sync.
#pragma once
#include <stdint.h>

namespace dug {

// 6E1D000n-D0C0-4B1A-9C55-55505F444F47, byte-reversed (little-endian) as Bluefruit expects.
#define DUG_UUID(n) \
  { 0x47, 0x4F, 0x44, 0x5F, 0x50, 0x55, 0x55, 0x9C, 0x1A, 0x4B, 0xC0, 0xD0, (n), 0x00, 0x1D, 0x6E }

// Control characteristic (write with response): phone -> collar commands.
enum Op : uint8_t {
  OP_PLAY         = 0x01,  // [id]
  OP_STOP         = 0x02,
  OP_SET_VOLUME   = 0x03,  // [volume 0-255]
  OP_DELETE       = 0x04,  // [id]
  OP_LIST         = 0x05,
  OP_UPLOAD_BEGIN = 0x10,  // [id][size u32][tag u32][flags][name utf8...]
  OP_UPLOAD_ABORT = 0x11,
};

enum UploadFlags : uint8_t {
  UPLOAD_PLAY_WHEN_DONE = 0x01,
};

// Status characteristic (notify): collar -> phone.
enum Status : uint8_t {
  ST_STATE        = 0x80,  // [volume][maxVolume][playingId or 0][freeKB u16]
  ST_CLIP         = 0x81,  // [id][size u32][tag u32][name utf8...]
  ST_LIST_END     = 0x82,
  ST_UPLOAD_ACK   = 0x90,  // [bytesCommitted u32]  (0 = ready for data)
  ST_UPLOAD_DONE  = 0x91,  // [id]
  ST_UPLOAD_ERROR = 0x92,  // [error]
  ST_PLAY_STARTED = 0xA0,  // [id]
  ST_PLAY_STOPPED = 0xA1,  // [id]
  ST_ERROR        = 0xEE,  // [error]
};

enum Error : uint8_t {
  ERR_BUSY         = 1,
  ERR_NO_SUCH_CLIP = 2,
  ERR_FLASH_FULL   = 3,
  ERR_BAD_COMMAND  = 4,
  ERR_OVERFLOW     = 5,
  ERR_FILESYSTEM   = 6,
};

// Audio is raw G.711 mu-law, mono, 16 kHz. No header.
constexpr uint32_t kSampleRate   = 16000;
constexpr uint8_t  kScratchClip  = 255;     // "say this now" clips overwrite this slot
constexpr uint8_t  kMaxNameBytes = 40;
constexpr uint32_t kMaxClipBytes = 30 * kSampleRate;  // 30 seconds
constexpr uint32_t kAckEvery     = 1024;    // collar acks every N committed bytes
// The app never has more than 4096 unacknowledged bytes in flight; the receive ring is bigger.

}  // namespace dug
