// I2S audio output for a MAX98357A amp, driven straight from the nRF52840's I2S peripheral.
// Plays 16 kHz mu-law pulled from a source callback, double-buffered via EasyDMA.
#pragma once
#include <Arduino.h>

namespace AudioOut {

// Fills `out` with up to `max` mu-law bytes; returns how many were written (0 = end of clip).
using Source = size_t (*)(uint8_t* out, size_t max);

// pinAmpEnable drives the MAX98357A SD pin so the amp is fully off (no hiss) when idle; -1 if unused.
void begin(uint8_t pinBclk, uint8_t pinLrc, uint8_t pinDin, int pinAmpEnable);

void start(Source source);
void stop();
bool isPlaying();

// 0-255, linear. Clamped to maxVolume.
void setVolume(uint8_t volume);
uint8_t volume();
void setMaxVolume(uint8_t maxVolume);
uint8_t maxVolume();

// Call often from loop(): refills DMA buffers and shuts down at the end of a clip.
void service();

int16_t decodeMuLaw(uint8_t byte);

}  // namespace AudioOut
