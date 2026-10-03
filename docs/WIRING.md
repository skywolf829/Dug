# Wiring

```
ItsyBitsy nRF52840          MAX98357A I2S amp            Speaker
-------------------         ------------------           -------
Vhi  ─────────────────────  Vin                          4–8 Ω, 2–3 W
G    ─────────────────────  GND                          + ── amp +
D11  ─────────────────────  BCLK                         – ── amp –
D10  ─────────────────────  LRC
D9   ─────────────────────  DIN
D12  ─────────────────────  SD      (amp on/off)
                            GAIN    leave unconnected (9 dB)

LiPo (3.7 V) ── BAT / G
```

Pins are set at the top of `firmware/DugCollar/DugCollar.ino`.

## Notes

- **SD pin:** the firmware holds it low (amp fully off) when nothing is playing. This saves
  battery and gets rid of idle hiss. When driven high (3.3 V) the amp plays the left channel.
  The firmware writes the same sample to both channels, so that's fine.
- **Power:** `Vhi` is whichever is higher, USB or battery. The amp gets louder at higher voltage.
- **Charging:** the ItsyBitsy nRF52840 has **no LiPo charger**. Use a separate one, e.g. Adafruit's
  LiPoly Backpack for ItsyBitsy (#2124), which solders straight on, or a Micro-LiPo charger board.
  A 500 mAh pack should comfortably last a night of trick-or-treating.
- **Button:** the onboard **SW** button plays clip 3 ("Squirrel!"), which is handy for testing
  without a phone.
- **LED:** the red LED is on while audio plays. A fast blink at boot means the flash failed to mount.
- **Puppy:** keep the box light and padded, point the speaker away from the dog's ears, and keep
  `MAX_VOLUME` in the firmware conservative.
