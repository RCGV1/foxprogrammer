# PicoFox file contract

Source of truth for this build: [firmware at c69af3a](https://github.com/ai6ym/PicoFox/blob/c69af3a6079e42637678bccb91373134535c4ce6/PicoFox-Firmware/PicoFox-Firmware.ino), inspected October 20, 2026. The [product manual](https://store.ai6ym.radio/pages/picofox) is the user-facing reference. The app uses conservative validation where they differ.

## Volume contents

| Filename | Owner | App behavior |
|---|---|---|
| `settings.txt` | User configuration | Read/edit/write UTF-8 text, LF output |
| `audio.wav` | User audio | Read if present; replace only on explicit save |
| `.callsign.wav` | Firmware-generated ID | Never edit |
| `.settings_crc.bin` | Firmware settings-change bookkeeping | Never edit |

No custom folder, backup, or draft is stored on the radio. The app does not reformat, delete, flash or eject the volume. The radio’s FAT16 filesystem is exposed via TinyUSB mass storage. Device settings/audio become effective after USB disconnect and power cycle.

Published firmware has USB serial diagnostics but no application command parser for reboot or settings reload. MSC flush synchronizes flash; it does not apply new settings. The inspected USB stack's 1200-baud touch enters the upload bootloader, not a normal restart. Installed firmware identity and startup persistence need verification before adding control commands. See [serial-control findings and extension contract](SERIAL-CONTROL.md).

## Settings schema

Input is case-sensitive `KEY=value`, one per line. Whitespace around keys and values is trimmed. Last recognized duplicate wins on import. Invalid numeric known values fail import. Blank/comment/unknown lines survive export; duplicate known keys collapse to one. Known keys absent from input are appended. Existing UTF-8 text must decode successfully. Output is LF-terminated UTF-8 without BOM and six decimal places for MHz, independent of locale.

| Key | App default | App accepted values |
|---|---:|---|
| `CALLSIGN` | empty (cannot export until valid) | 1–11 ASCII uppercase letters/digits |
| `ITU_ZONE` | 2 | 1, 2, 3 |
| `FREQ_MHZ` | 146.565 | Finite; 144.020–145.980 in zone 1, 144.020–147.980 in zones 2/3, inclusive |
| `DUTY_CYCLE` | 100 | Integer 0–100 |
| `ATTENUATION` | 0 | Integer 0–127; approximately 0.25 dB/step; r3 only |
| `MORSE_WPM` | 15 | Integer 1–30 |
| `MORSE_FARNSWORTH_WPM` | 15 | Integer Morse speed through 255 |
| `MORSE_TONE` | 600 | Integer 100–2000 Hz (conservative manual range) |
| `MORSE_TONE_VOL` | 70 | Integer 1–100 |

Draft JSON uses the Swift model property names: `callsign`, `ituZone`, `frequencyMHz`, `dutyCycle`, `attenuation`, `morseWPM`, `farnsworthWPM`, `toneHz`, `toneVolume`. It is app persistence rather than a versioned exchange format. Device text and WAV are the cross-platform exchange formats.

## Firmware differences that matter

- **Callsign:** the manual advertises 12 characters; `char callsign[12]` plus `strncpy(..., sizeof(...) - 1)` allows 11 plus a terminator. App enforces 11 to avoid silent truncation.
- **Band edges:** `FM_DEVIATION_HZ` is 10,000; the loader reserves twice that at each band edge. The app validates the resulting 20 kHz margins.
- **Farnsworth:** firmware default is 10, but loader raises values below Morse WPM to Morse WPM. The app starts at effective default 15 and reports invalid spacing without silently rewriting the user’s value. This is the current firmware behavior, not conventional slower Farnsworth timing.
- **Tone:** loader accepts 100–2499 Hz, while manual recommends 100–2000. App uses the manual’s narrower range.
- **Duty cycle:** firmware uses `offTime = ((100 - dutyCyclePercent) * audioLengthMs) / 100`. It does not compute a standard on/(on+off) percentage; the app stores the configured number and does not promise a true duty-cycle estimate.
- **WAV:** playback reads 44 header bytes, checks RIFF/WAVE magic, then reads every subsequent pair as a sample. Chunk metadata or trailing bytes can become transmitted sound. Output must be a canonical, metadata-free header and payload.

## Canonical audio.wav byte layout

All integers little endian. No extension chunks or trailing metadata.

| Offset | Length | Value |
|---:|---:|---|
| 0 | 4 | ASCII RIFF |
| 4 | 4 | 36 + payload byte count |
| 8 | 4 | ASCII WAVE |
| 12 | 4 | ASCII fmt + space |
| 16 | 4 | 16 |
| 20 | 2 | Format 1 (PCM) |
| 22 | 2 | Channels 1 |
| 24 | 4 | Rate 5000 |
| 28 | 4 | Byte rate 10000 |
| 32 | 2 | Block alignment 2 |
| 34 | 2 | Bits 16 |
| 36 | 4 | ASCII data |
| 40 | 4 | Payload byte count |
| 44 | N | Signed PCM16 mono samples |

Duration = payloadBytes / 10000 seconds. Device file size = 44 + payloadBytes. Available device capacity must be evaluated by actual filesystem writes; the app’s 12 MB limit is a resource policy, not a promise about free flash.

## Power slider

The UI presents power instead of attenuation. It keeps the firmware ATTENUATION field and maps 128 discrete slider positions with `attenuation = 127 - sliderStep`. Nominal base output is `65 × 10^(-attenuation × 0.25 / 10)` mW. Thus steps 0, 40 and 80 correspond to nominal 65, 6.5 and 0.65 mW. The increasing slider runs approximately 0.0434–65 mW.

This is a calculation from the published maximum and approximate attenuation step, not an RF measurement. Values carry ≈ in the UI. Hardware revision, frequency, supply, device variation and firmware attenuation cycling can change actual output. r2 ignores attenuation entirely; the slider is an r3 control. Exact power requires measured calibration data, which is not available in this delivery.

## Firmware-generated length fields

At the inspected firmware commit, audio.h declares 300,000 PCM data bytes while six 48,000-byte repetitions create 288,000 bytes. The resulting default file is 288,044 bytes but its RIFF/data lengths advertise 300,044/300,000. `decodePicoFox` first tries strict WAV parsing, then accepts only the proven factory case: actual length 288,044 bytes, declared RIFF file length 300,044 bytes and declared PCM payload 300,000 bytes, with the canonical PCM16 mono 5 kHz layout. Other truncations are rejected. Lengths are corrected in a local memory copy; the source file is unchanged. Regular WAV import remains strict. Canonical export always writes correct lengths.

A readable header mismatch is separate from a filesystem read failure. Lost FAT cluster links cannot be repaired by WAV parsing. The folder adapter reports unreadable audio separately and still opens settings; it refuses direct replacement when the original cannot be read/backed up.

## Firmware-generated callsign audio

At the documented firmware baseline, the Morse generator writes a fixed WAV header before producing variable-length samples. FoxProgrammer does not read or write the hidden `.callsign.wav` file. Explicit import uses strict WAV validation; the factory-audio compatibility exception does not apply to arbitrary short files.
