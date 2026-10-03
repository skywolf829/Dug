// Clip storage on the ItsyBitsy's 2 MB QSPI flash, using LittleFS (power-loss safe, auto-formats).
//   /c/<id>.a  raw mu-law audio
//   /c/<id>.m  metadata: [tag u32][name utf8]
#pragma once
#include <Arduino.h>
#include "Protocol.h"

namespace ClipStore {

struct Info {
  uint8_t id;
  uint32_t size;
  uint32_t tag;
  uint8_t nameLen;
  char name[dug::kMaxNameBytes];
};

bool begin();

bool info(uint8_t id, Info& out);
bool remove(uint8_t id);
uint32_t freeBytes();

// Calls fn(info) for every stored clip.
void forEach(void (*fn)(const Info&));

// Playback: one clip open at a time.
bool openForPlayback(uint8_t id);
size_t readPlayback(uint8_t* out, size_t max);
void closePlayback();

// Upload: written to a temp file, then swapped in atomically by commit().
bool beginWrite();
bool write(const uint8_t* data, size_t len);
bool commit(uint8_t id, uint32_t tag, const char* name, uint8_t nameLen);
void abortWrite();

}  // namespace ClipStore
