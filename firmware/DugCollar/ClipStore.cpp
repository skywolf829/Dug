#include "ClipStore.h"

#include <Adafruit_LittleFS.h>
#include <Adafruit_SPIFlash.h>

using LfsFile = Adafruit_LittleFS_Namespace::File;
using Adafruit_LittleFS_Namespace::FILE_O_READ;
using Adafruit_LittleFS_Namespace::FILE_O_WRITE;

namespace ClipStore {
namespace {

constexpr uint32_t kBlockSize = 4096;  // flash erase sector
const char* const kTempPath = "/c/tmp";

Adafruit_FlashTransport_QSPI s_transport;
Adafruit_SPIFlash s_flash(&s_transport);

int flashRead(const struct lfs_config* c, lfs_block_t block, lfs_off_t off, void* buffer, lfs_size_t size) {
  return s_flash.readBuffer(block * c->block_size + off, (uint8_t*)buffer, size) == size ? 0 : LFS_ERR_IO;
}
int flashProg(const struct lfs_config* c, lfs_block_t block, lfs_off_t off, const void* buffer, lfs_size_t size) {
  return s_flash.writeBuffer(block * c->block_size + off, (const uint8_t*)buffer, size) == size ? 0 : LFS_ERR_IO;
}
int flashErase(const struct lfs_config* c, lfs_block_t block) {
  return s_flash.eraseSector(block) ? 0 : LFS_ERR_IO;
}
int flashSync(const struct lfs_config* c) {
  s_flash.waitUntilReady();
  return 0;
}

struct lfs_config s_cfg = {
  .context = nullptr,
  .read = flashRead,
  .prog = flashProg,
  .erase = flashErase,
  .sync = flashSync,
  .read_size = 256,
  .prog_size = 256,
  .block_size = kBlockSize,
  .block_count = 0,  // set from the detected flash size in begin()
  .lookahead = 512,
  .read_buffer = nullptr,
  .prog_buffer = nullptr,
  .lookahead_buffer = nullptr,
  .file_buffer = nullptr,
};

Adafruit_LittleFS s_fs;
LfsFile s_play(s_fs);
LfsFile s_upload(s_fs);

void audioPath(char* buf, uint8_t id) { snprintf(buf, 12, "/c/%u.a", id); }
void metaPath(char* buf, uint8_t id) { snprintf(buf, 12, "/c/%u.m", id); }

int countBlock(void* count, lfs_block_t) {
  (*(uint32_t*)count)++;
  return 0;
}

}  // namespace

bool begin() {
  if (!s_flash.begin()) return false;
  s_cfg.block_count = s_flash.size() / kBlockSize;

  if (!s_fs.begin(&s_cfg)) {
    // First boot (or flash previously used by CircuitPython): format it.
    if (!s_fs.format() || !s_fs.begin(&s_cfg)) return false;
  }
  if (!s_fs.exists("/c")) s_fs.mkdir("/c");
  s_fs.remove(kTempPath);
  return true;
}

bool info(uint8_t id, Info& out) {
  char path[12];
  audioPath(path, id);
  LfsFile audio = s_fs.open(path, FILE_O_READ);
  if (!audio) return false;
  out.id = id;
  out.size = audio.size();
  audio.close();

  out.tag = 0;
  out.nameLen = 0;
  metaPath(path, id);
  LfsFile meta = s_fs.open(path, FILE_O_READ);
  if (meta) {
    meta.read(&out.tag, sizeof(out.tag));
    int n = meta.read(out.name, sizeof(out.name));
    out.nameLen = n > 0 ? n : 0;
    meta.close();
  }
  return true;
}

bool remove(uint8_t id) {
  char path[12];
  audioPath(path, id);
  bool existed = s_fs.remove(path);
  metaPath(path, id);
  s_fs.remove(path);
  return existed;
}

uint32_t freeBytes() {
  uint32_t used = 0;
  s_fs._lockFS();
  lfs_traverse(s_fs._getFS(), countBlock, &used);
  s_fs._unlockFS();
  return used >= s_cfg.block_count ? 0 : (s_cfg.block_count - used) * kBlockSize;
}

void forEach(void (*fn)(const Info&)) {
  LfsFile dir = s_fs.open("/c", FILE_O_READ);
  if (!dir) return;
  // Collect ids first so fn() is free to open files.
  uint8_t ids[256];
  int count = 0;
  for (LfsFile f = dir.openNextFile(); f; f = dir.openNextFile()) {
    const char* name = f.name();
    size_t len = strlen(name);
    if (len > 2 && name[len - 2] == '.' && name[len - 1] == 'a' && isdigit(name[0])) {
      int id = atoi(name);
      if (id > 0 && id < 256 && count < 256) ids[count++] = (uint8_t)id;
    }
    f.close();
  }
  dir.close();

  Info clip;
  for (int i = 0; i < count; i++) {
    if (info(ids[i], clip)) fn(clip);
  }
}

bool openForPlayback(uint8_t id) {
  closePlayback();
  char path[12];
  audioPath(path, id);
  return s_play.open(path, FILE_O_READ);
}

size_t readPlayback(uint8_t* out, size_t max) {
  if (!s_play) return 0;
  int n = s_play.read(out, max);
  return n > 0 ? n : 0;
}

void closePlayback() {
  if (s_play) s_play.close();
}

bool beginWrite() {
  abortWrite();
  return s_upload.open(kTempPath, FILE_O_WRITE);
}

bool write(const uint8_t* data, size_t len) {
  return s_upload && s_upload.write(data, len) == len;
}

bool commit(uint8_t id, uint32_t tag, const char* name, uint8_t nameLen) {
  if (!s_upload) return false;
  s_upload.close();

  remove(id);
  char path[12];
  audioPath(path, id);
  if (!s_fs.rename(kTempPath, path)) return false;

  metaPath(path, id);
  LfsFile meta = s_fs.open(path, FILE_O_WRITE);
  if (meta) {
    meta.write((const uint8_t*)&tag, sizeof(tag));
    meta.write((const uint8_t*)name, nameLen);
    meta.close();
  }
  return true;
}

void abortWrite() {
  if (s_upload) s_upload.close();
  s_fs.remove(kTempPath);
}

}  // namespace ClipStore
