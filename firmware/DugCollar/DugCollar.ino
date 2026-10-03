// Dug's talking collar — Adafruit ItsyBitsy nRF52840 Express + MAX98357A I2S amp.
//
// Phones connect over BLE (up to two at once), trigger stored clips, and upload new ones
// (presets or freshly synthesized speech). Protocol: docs/PROTOCOL.md. Wiring: docs/WIRING.md.

#include <bluefruit.h>

#include "AudioOut.h"
#include "ClipStore.h"
#include "Protocol.h"

using namespace dug;

// ---- Config -------------------------------------------------------------------------------

constexpr uint8_t PIN_I2S_BCLK = 11;
constexpr uint8_t PIN_I2S_LRC  = 10;
constexpr uint8_t PIN_I2S_DIN  = 9;
constexpr int     PIN_AMP_SD   = 12;           // MAX98357A SD (shutdown) pin
constexpr uint8_t PIN_BUTTON   = PIN_BUTTON1;  // the ItsyBitsy's onboard "SW" button

// A speaker on a puppy's neck is right next to very good ears. Keep this conservative and
// raise it only after listening on the actual collar. 0-255.
constexpr uint8_t MAX_VOLUME     = 170;
constexpr uint8_t DEFAULT_VOLUME = 120;

constexpr uint8_t BUTTON_CLIP = 3;  // "Squirrel!" in the app's preset list

constexpr uint8_t MAX_CONNECTIONS = 2;  // one phone each
constexpr uint32_t UPLOAD_TIMEOUT_MS = 5000;

// ---- BLE ----------------------------------------------------------------------------------

const uint8_t UUID_SERVICE[] = DUG_UUID(0x01);
const uint8_t UUID_CONTROL[] = DUG_UUID(0x02);
const uint8_t UUID_DATA[]    = DUG_UUID(0x03);
const uint8_t UUID_STATUS[]  = DUG_UUID(0x04);

BLEService dugService(UUID_SERVICE);
BLECharacteristic controlChr(UUID_CONTROL);
BLECharacteristic dataChr(UUID_DATA);
BLECharacteristic statusChr(UUID_STATUS);

// Commands arrive on the BLE task; they're queued and handled in loop() so that all flash
// and audio work happens on one thread.
struct Command {
  uint16_t conn;
  uint8_t len;
  uint8_t data[64];
};
constexpr uint8_t kCommandSlots = 8;
Command g_commands[kCommandSlots];
volatile uint8_t g_cmdHead = 0, g_cmdTail = 0;

// Upload data lands in this ring from the BLE task and is drained to flash by loop().
constexpr uint32_t kRingSize = 8192;
uint8_t g_ring[kRingSize];
volatile uint32_t g_ringHead = 0, g_ringTail = 0;  // monotonic byte counters

struct Upload {
  volatile bool active;
  volatile bool overflow;
  uint16_t conn;
  uint8_t id;
  uint32_t size;
  uint32_t tag;
  bool playWhenDone;
  uint8_t nameLen;
  char name[kMaxNameBytes];
  uint32_t written;
  uint32_t lastAck;
  uint32_t lastActivityMs;
} g_upload;

uint8_t g_playingId = 0;

// ---- Notifications ------------------------------------------------------------------------

void notifyAll(const uint8_t* data, uint16_t len) {
  for (uint16_t h = 0; h < BLE_MAX_CONNECTION; h++) {
    if (!Bluefruit.connected(h) || !statusChr.notifyEnabled(h)) continue;
    uint16_t mtuPayload = Bluefruit.Connection(h)->getMtu() - 3;
    statusChr.notify(h, data, min(len, mtuPayload));
  }
}

void putU32(uint8_t* p, uint32_t v) {
  p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}
uint32_t getU32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

void notify1(uint8_t status, uint8_t value) {
  uint8_t msg[2] = { status, value };
  notifyAll(msg, sizeof(msg));
}

void notifyState() {
  uint16_t freeKB = min<uint32_t>(ClipStore::freeBytes() / 1024, 0xFFFF);
  uint8_t msg[] = { ST_STATE, AudioOut::volume(), AudioOut::maxVolume(), g_playingId,
                    (uint8_t)freeKB, (uint8_t)(freeKB >> 8) };
  notifyAll(msg, sizeof(msg));
}

void notifyClip(const ClipStore::Info& clip) {
  uint8_t msg[10 + kMaxNameBytes];
  msg[0] = ST_CLIP;
  msg[1] = clip.id;
  putU32(msg + 2, clip.size);
  putU32(msg + 6, clip.tag);
  memcpy(msg + 10, clip.name, clip.nameLen);
  notifyAll(msg, 10 + clip.nameLen);
}

void notifyAck(uint32_t committed) {
  uint8_t msg[5] = { ST_UPLOAD_ACK };
  putU32(msg + 1, committed);
  notifyAll(msg, sizeof(msg));
}

// ---- Playback -----------------------------------------------------------------------------

size_t playbackSource(uint8_t* out, size_t max) { return ClipStore::readPlayback(out, max); }

void stopPlayback() {
  if (!g_playingId) return;
  AudioOut::stop();
  ClipStore::closePlayback();
  digitalWrite(LED_BUILTIN, LOW);
  notify1(ST_PLAY_STOPPED, g_playingId);
  g_playingId = 0;
}

void startPlayback(uint8_t id) {
  if (g_upload.active) return notify1(ST_ERROR, ERR_BUSY);
  stopPlayback();
  if (!ClipStore::openForPlayback(id)) return notify1(ST_ERROR, ERR_NO_SUCH_CLIP);
  AudioOut::start(playbackSource);
  g_playingId = id;
  digitalWrite(LED_BUILTIN, HIGH);
  notify1(ST_PLAY_STARTED, id);
}

// ---- Upload -------------------------------------------------------------------------------

void failUpload(uint8_t err) {
  g_upload.active = false;
  ClipStore::abortWrite();
  notify1(ST_UPLOAD_ERROR, err);
}

void beginUpload(uint16_t conn, const uint8_t* d, uint8_t len) {
  if (len < 11) return notify1(ST_UPLOAD_ERROR, ERR_BAD_COMMAND);
  if (g_upload.active) return notify1(ST_UPLOAD_ERROR, ERR_BUSY);

  uint32_t size = getU32(d + 2);
  if (size == 0 || size > kMaxClipBytes) return notify1(ST_UPLOAD_ERROR, ERR_BAD_COMMAND);
  if (size + 8192 > ClipStore::freeBytes()) return notify1(ST_UPLOAD_ERROR, ERR_FLASH_FULL);

  stopPlayback();  // keep flash writes and audio from fighting over the loop
  if (!ClipStore::beginWrite()) return notify1(ST_UPLOAD_ERROR, ERR_FILESYSTEM);

  g_upload.conn = conn;
  g_upload.id = d[1];
  g_upload.size = size;
  g_upload.tag = getU32(d + 6);
  g_upload.playWhenDone = d[10] & UPLOAD_PLAY_WHEN_DONE;
  g_upload.nameLen = min<uint8_t>(len - 11, kMaxNameBytes);
  memcpy(g_upload.name, d + 11, g_upload.nameLen);
  g_upload.written = 0;
  g_upload.lastAck = 0;
  g_upload.lastActivityMs = millis();
  g_upload.overflow = false;
  g_ringHead = g_ringTail = 0;
  g_upload.active = true;

  notifyAck(0);  // "ready": the app waits for this before streaming data
}

void serviceUpload() {
  if (!g_upload.active) return;

  if (g_upload.overflow) return failUpload(ERR_OVERFLOW);
  if (g_ringHead > g_upload.size) return failUpload(ERR_BAD_COMMAND);

  // Drain the ring to flash in contiguous runs.
  while (g_ringTail < g_ringHead) {
    uint32_t start = g_ringTail % kRingSize;
    uint32_t run = min(g_ringHead - g_ringTail, kRingSize - start);
    if (!ClipStore::write(g_ring + start, run)) return failUpload(ERR_FILESYSTEM);
    g_ringTail += run;
    g_upload.written += run;
    g_upload.lastActivityMs = millis();
  }

  if (g_upload.written == g_upload.size) {
    g_upload.active = false;
    if (!ClipStore::commit(g_upload.id, g_upload.tag, g_upload.name, g_upload.nameLen)) {
      ClipStore::abortWrite();
      return notify1(ST_UPLOAD_ERROR, ERR_FILESYSTEM);
    }
    notifyAck(g_upload.written);
    notify1(ST_UPLOAD_DONE, g_upload.id);
    ClipStore::Info clip;
    if (ClipStore::info(g_upload.id, clip)) notifyClip(clip);
    notifyState();
    if (g_upload.playWhenDone) startPlayback(g_upload.id);
    return;
  }

  if (g_upload.written - g_upload.lastAck >= kAckEvery) {
    g_upload.lastAck = g_upload.written;
    notifyAck(g_upload.written);
  }

  if (millis() - g_upload.lastActivityMs > UPLOAD_TIMEOUT_MS) failUpload(ERR_BAD_COMMAND);
}

// ---- Commands -----------------------------------------------------------------------------

void handleCommand(const Command& cmd) {
  const uint8_t* d = cmd.data;
  switch (d[0]) {
    case OP_PLAY:
      if (cmd.len >= 2) startPlayback(d[1]);
      break;
    case OP_STOP:
      stopPlayback();
      break;
    case OP_SET_VOLUME:
      if (cmd.len >= 2) {
        AudioOut::setVolume(d[1]);
        notifyState();
      }
      break;
    case OP_DELETE:
      if (cmd.len >= 2) {
        if (g_playingId == d[1]) stopPlayback();
        if (!ClipStore::remove(d[1])) notify1(ST_ERROR, ERR_NO_SUCH_CLIP);
        notifyState();
      }
      break;
    case OP_LIST:
      notifyState();
      ClipStore::forEach(notifyClip);
      notify1(ST_LIST_END, 0);
      break;
    case OP_UPLOAD_BEGIN:
      beginUpload(cmd.conn, d, cmd.len);
      break;
    case OP_UPLOAD_ABORT:
      if (g_upload.active) failUpload(ERR_BAD_COMMAND);
      break;
    default:
      notify1(ST_ERROR, ERR_BAD_COMMAND);
  }
}

// BLE task callbacks: copy and get out.
void onControlWrite(uint16_t conn, BLECharacteristic*, uint8_t* data, uint16_t len) {
  if (len == 0) return;
  uint8_t next = (g_cmdHead + 1) % kCommandSlots;
  if (next == g_cmdTail) return;  // queue full; phone will see no response and can retry
  Command& slot = g_commands[g_cmdHead];
  slot.conn = conn;
  slot.len = min<uint16_t>(len, sizeof(slot.data));
  memcpy(slot.data, data, slot.len);
  g_cmdHead = next;
}

void onDataWrite(uint16_t conn, BLECharacteristic*, uint8_t* data, uint16_t len) {
  if (!g_upload.active || conn != g_upload.conn) return;
  uint32_t head = g_ringHead;
  if (head - g_ringTail + len > kRingSize) {
    g_upload.overflow = true;
    return;
  }
  for (uint16_t i = 0; i < len; i++) g_ring[(head + i) % kRingSize] = data[i];
  g_ringHead = head + len;
}

void onConnect(uint16_t conn) {
  // Keep advertising so the second phone can join.
  if (Bluefruit.connected() < MAX_CONNECTIONS) Bluefruit.Advertising.start(0);
}

void onDisconnect(uint16_t conn, uint8_t reason) {
  if (g_upload.active && g_upload.conn == conn) g_upload.overflow = true;  // abort in loop()
  if (!Bluefruit.Advertising.isRunning()) Bluefruit.Advertising.start(0);
}

void setupBLE() {
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);  // 247-byte MTU, bigger queues
  Bluefruit.begin(MAX_CONNECTIONS, 0);
  Bluefruit.setName("Dug's Collar");
  Bluefruit.setTxPower(4);
  Bluefruit.Periph.setConnectCallback(onConnect);
  Bluefruit.Periph.setDisconnectCallback(onDisconnect);

  dugService.begin();

  controlChr.setProperties(CHR_PROPS_WRITE);
  controlChr.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  controlChr.setMaxLen(64);
  controlChr.setWriteCallback(onControlWrite, false);  // run directly on the BLE task
  controlChr.begin();

  dataChr.setProperties(CHR_PROPS_WRITE_WO_RESP);
  dataChr.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  dataChr.setMaxLen(244);
  dataChr.setWriteCallback(onDataWrite, false);
  dataChr.begin();

  statusChr.setProperties(CHR_PROPS_NOTIFY);
  statusChr.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  statusChr.setMaxLen(244);
  statusChr.begin();

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(dugService);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);  // 20 ms fast, 152.5 ms slow
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

// ---- Main ---------------------------------------------------------------------------------

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  pinMode(PIN_BUTTON, INPUT_PULLUP);

  AudioOut::begin(PIN_I2S_BCLK, PIN_I2S_LRC, PIN_I2S_DIN, PIN_AMP_SD);
  AudioOut::setMaxVolume(MAX_VOLUME);
  AudioOut::setVolume(DEFAULT_VOLUME);

  if (!ClipStore::begin()) {
    // No flash, no clips. Blink forever so it's obvious something is wrong.
    while (true) {
      digitalToggle(LED_BUILTIN);
      delay(100);
    }
  }

  setupBLE();
}

void serviceButton() {
  static bool wasDown = false;
  static uint32_t lastChangeMs = 0;
  bool down = digitalRead(PIN_BUTTON) == LOW;
  if (down != wasDown && millis() - lastChangeMs > 30) {
    wasDown = down;
    lastChangeMs = millis();
    if (down) startPlayback(BUTTON_CLIP);
  }
}

void loop() {
  AudioOut::service();
  if (g_playingId && !AudioOut::isPlaying()) stopPlayback();

  while (g_cmdTail != g_cmdHead) {
    handleCommand(g_commands[g_cmdTail]);
    g_cmdTail = (g_cmdTail + 1) % kCommandSlots;
  }

  serviceUpload();
  serviceButton();
  AudioOut::service();
  yield();
}
