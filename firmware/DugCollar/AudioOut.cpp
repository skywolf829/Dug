#include "AudioOut.h"

namespace AudioOut {
namespace {

// 1024 frames at ~16 kHz = 64 ms per buffer; loop() has that long to refill the idle one.
constexpr size_t kFrames = 1024;

// Each 32-bit word is one stereo frame (left in the low half, right in the high half).
// We write the same sample to both channels; the MAX98357A plays (L+R)/2 by default.
uint32_t s_buf[2][kFrames];
uint8_t s_scratch[kFrames];
int16_t s_ulaw[256];

volatile bool s_needFill[2];
volatile uint32_t s_events;
volatile uint8_t s_next;

Source s_source = nullptr;
bool s_playing = false;
bool s_draining = false;
uint32_t s_stopAt = 0;
uint8_t s_volume = 160;
uint8_t s_maxVolume = 255;
int s_pinAmp = -1;

int16_t muLawToLinear(uint8_t u) {
  u = ~u;
  int32_t t = ((u & 0x0F) << 3) + 0x84;
  t <<= (u & 0x70) >> 4;
  return (u & 0x80) ? (0x84 - t) : (t - 0x84);
}

// Fills buffer `idx`. `eventsUntilDone` is how many TXPTRUPD events from now until this
// buffer has been fully clocked out (2 normally; 3 for the second buffer primed at start).
void fill(uint8_t idx, uint8_t eventsUntilDone) {
  size_t n = (s_source && !s_draining) ? s_source(s_scratch, kFrames) : 0;
  int32_t vol = s_volume;
  uint32_t* out = s_buf[idx];
  for (size_t i = 0; i < n; i++) {
    uint16_t v = (uint16_t)(int16_t)((s_ulaw[s_scratch[i]] * vol) >> 8);
    out[i] = ((uint32_t)v << 16) | v;
  }
  memset(out + n, 0, (kFrames - n) * sizeof(uint32_t));
  if (n < kFrames && !s_draining) {
    s_draining = true;
    s_stopAt = s_events + eventsUntilDone;
  }
}

void ampEnable(bool on) {
  if (s_pinAmp >= 0) digitalWrite(s_pinAmp, on ? HIGH : LOW);
}

}  // namespace

int16_t decodeMuLaw(uint8_t byte) { return s_ulaw[byte]; }

void begin(uint8_t pinBclk, uint8_t pinLrc, uint8_t pinDin, int pinAmpEnable) {
  for (int i = 0; i < 256; i++) s_ulaw[i] = muLawToLinear((uint8_t)i);

  s_pinAmp = pinAmpEnable;
  if (s_pinAmp >= 0) pinMode(s_pinAmp, OUTPUT);
  ampEnable(false);

  // MCK 32 MHz / 31 = 1.032 MHz, LRCK = MCK / 64 = 16.13 kHz (0.8% fast — nobody will notice).
  NRF_I2S->CONFIG.MODE     = I2S_CONFIG_MODE_MODE_Master;
  NRF_I2S->CONFIG.TXEN     = I2S_CONFIG_TXEN_TXEN_Enabled;
  NRF_I2S->CONFIG.RXEN     = I2S_CONFIG_RXEN_RXEN_Disabled;
  NRF_I2S->CONFIG.MCKEN    = I2S_CONFIG_MCKEN_MCKEN_Enabled;
  NRF_I2S->CONFIG.MCKFREQ  = I2S_CONFIG_MCKFREQ_MCKFREQ_32MDIV31;
  NRF_I2S->CONFIG.RATIO    = I2S_CONFIG_RATIO_RATIO_64X;
  NRF_I2S->CONFIG.SWIDTH   = I2S_CONFIG_SWIDTH_SWIDTH_16Bit;
  NRF_I2S->CONFIG.ALIGN    = I2S_CONFIG_ALIGN_ALIGN_Left;
  NRF_I2S->CONFIG.FORMAT   = I2S_CONFIG_FORMAT_FORMAT_I2S;
  NRF_I2S->CONFIG.CHANNELS = I2S_CONFIG_CHANNELS_CHANNELS_Stereo;

  // g_ADigitalPinMap gives port*32+pin, which is exactly the PSEL encoding (CONNECT bit = 0).
  NRF_I2S->PSEL.MCK   = 0xFFFFFFFF;  // disconnected; the MAX98357A doesn't need it
  NRF_I2S->PSEL.SCK   = g_ADigitalPinMap[pinBclk];
  NRF_I2S->PSEL.LRCK  = g_ADigitalPinMap[pinLrc];
  NRF_I2S->PSEL.SDOUT = g_ADigitalPinMap[pinDin];
  NRF_I2S->PSEL.SDIN  = 0xFFFFFFFF;

  NVIC_SetPriority(I2S_IRQn, 3);
}

void start(Source source) {
  stop();
  s_source = source;
  s_draining = false;
  s_events = 0;
  s_needFill[0] = s_needFill[1] = false;

  fill(0, 2);
  fill(1, 3);

  NRF_I2S->TXD.PTR = (uint32_t)s_buf[0];
  NRF_I2S->RXTXD.MAXCNT = kFrames;
  s_next = 1;

  NRF_I2S->EVENTS_TXPTRUPD = 0;
  NRF_I2S->EVENTS_STOPPED = 0;
  NRF_I2S->INTENSET = I2S_INTENSET_TXPTRUPD_Msk;
  NVIC_ClearPendingIRQ(I2S_IRQn);
  NVIC_EnableIRQ(I2S_IRQn);

  NRF_I2S->ENABLE = 1;
  NRF_I2S->TASKS_START = 1;
  s_playing = true;
  delay(2);  // let clocks settle before un-muting to avoid a pop
  ampEnable(true);
}

void stop() {
  if (!s_playing) return;
  ampEnable(false);
  NRF_I2S->TASKS_STOP = 1;
  uint32_t t0 = millis();
  while (!NRF_I2S->EVENTS_STOPPED && millis() - t0 < 10) {}
  NRF_I2S->EVENTS_STOPPED = 0;
  NRF_I2S->INTENCLR = I2S_INTENCLR_TXPTRUPD_Msk;
  NVIC_DisableIRQ(I2S_IRQn);
  NRF_I2S->ENABLE = 0;
  s_playing = false;
  s_source = nullptr;
}

bool isPlaying() { return s_playing; }

void setVolume(uint8_t volume) { s_volume = min(volume, s_maxVolume); }
uint8_t volume() { return s_volume; }
void setMaxVolume(uint8_t maxVolume) {
  s_maxVolume = maxVolume;
  setVolume(s_volume);
}
uint8_t maxVolume() { return s_maxVolume; }

void service() {
  if (!s_playing) return;
  for (uint8_t i = 0; i < 2; i++) {
    if (s_needFill[i]) {
      s_needFill[i] = false;
      fill(i, 2);
    }
  }
  if (s_draining && s_events >= s_stopAt) stop();
}

}  // namespace AudioOut

// Fires each time the DMA latches TXD.PTR. The buffer we queue next is the one that just
// finished playing, so (after the first event) it gets flagged for loop() to refill.
extern "C" void I2S_IRQHandler(void) {
  using namespace AudioOut;
  if (NRF_I2S->EVENTS_TXPTRUPD) {
    NRF_I2S->EVENTS_TXPTRUPD = 0;
    uint8_t next = s_next;
    NRF_I2S->TXD.PTR = (uint32_t)s_buf[next];
    s_next = next ^ 1;
    if (++s_events >= 2) s_needFill[next] = true;
  }
}
