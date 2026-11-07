# FoxProgrammer application specification

The app is named **FoxProgrammer** as of version 1.0.8, build 9. The feature baseline below describes native SwiftUI version **1.0.7, build 8**, for iOS/iPadOS 17+ and macOS 14+. It is a behavioral reference for an Android implementation, not a requirement to reproduce Apple APIs. The current application edits files exposed by PicoFox USB mass storage. Firmware compatibility is pinned to c69af3a; selecting a folder does not identify a hardware revision or firmware version.

## Product and navigation

- Keep two screens: **Settings** and **Audio**. Compact iPhone uses tabs; wider iPad/Mac layouts use a sidebar. Folder selection, import/export and confirmations are native system presentations, not additional application screens.
- Use native forms, sliders, pickers, steppers, labeled actions and accessible field names. Narrow Audio layouts keep Record, Import, Tone and Speech labels in two rows. iOS actions have at least 44-point touch targets.
- Radio, tone, speech and trim fields share one focus owner. On iOS, only the active screen shows a full-width bottom Done bar while a field is focused; Done clears focus. Numeric fields use decimal keyboards, callsign uses ASCII/uppercase entry, and scrolling can dismiss the keyboard.
- Show progress only during work. Routine saves/changes do not produce success popups. Show actual failures and confirmations before folder reload/replacement or default-audio restoration. Cancelling a system file picker is silent.
- The app works as an offline settings/audio editor without a connected radio. Device saves require an available authorized folder; local exports remain usable offline.

## Settings screen

Display the selected folder name, Not connected or Disconnected, plus Connect/Change folder. Settings edits remain local until explicit save/export. The Files menu provides Open PicoFox folder, Reopen last folder, Close folder and Keep settings draft. Selecting/reloading a folder can replace the current session and requires confirmation when applicable.

| Field | Default | Validation / presentation |
|---|---:|---|
| Callsign | Empty | 1–11 ASCII uppercase letters/digits; entry uppercases text |
| ITU zone | 2 | Integer 1, 2 or 3 |
| Frequency | 146.565 MHz | Finite; zone 1: 144.020–145.980 MHz; zones 2/3: 144.020–147.980 MHz; inclusive |
| Duty cycle | 100% | Integer 0–100; stores firmware's parameter, not a measured on-time percentage |
| Power | ≈65 mW | 128 slider positions backed by integer attenuation 0–127; higher slider position means higher power |
| Morse speed | 15 WPM | Integer 1–30 |
| Morse spacing | 15 WPM | Integer from the selected Morse speed through 255 |
| Morse tone | 600 Hz | Integer 100–2000; UI step 50 Hz |
| Morse volume | 70% | Integer 1–100 |

Morse controls sit in a disclosure group. Frequency validation appears beside the field even when another field, such as callsign, is invalid. Inline feedback, aggregate validation and encoded output use the same frequency bounds. Invalid settings disable both Save to PicoFox and Export settings.txt; drafts may retain invalid intermediate values.

Power is calculated as `65 × 10^(-attenuation × 0.25 / 10)` mW. The slider maps `attenuation = 127 − sliderStep`, giving approximately 0.0434–65 mW. Display ≈: this is nominal r3 output from published values, not calibrated RF measurement. r2 ignores attenuation. Frequency, hardware, supply and firmware behavior can affect actual output. See [device contract](DEVICE-CONTRACT.md).

Settings text is UTF-8 `KEY=value`. Preserve comments and unknown lines, use the last recognized duplicate on import, collapse known duplicates on export, and append missing known keys. Reject malformed known numeric values. Output LF-terminated text and locale-independent MHz with six decimals. Do not silently reset malformed imported settings.

## Audio sources

All sources become finite, editable mono Float PCM with a sample rate and source name. Average channels for mono conversion; opposite-phase stereo can therefore cancel. Load a replacement only after successful decoding/generation; partial or failed work must not replace the current source.

| Action | Delivered behavior |
|---|---|
| Record | Request microphone permission on demand; capture mono 44.1 kHz PCM16 WAV. Stop on explicit Stop, two-minute limit, background or interruption; load only a closed, readable, nonempty file, then remove the temporary file. |
| Import | Use the system audio picker/decoder for supported WAV, AIFF, MP3, M4A/AAC and other formats. Protected or unsupported media can fail. Bound input to 64 MB, 1–8 channels, 1–192 kHz, ten minutes and 12 million decoded mono frames. |
| Tone | Inline frequency and duration controls; defaults 600 Hz / 3 s. Accept 100–2000 Hz and 0.1–60 s. Generate a 48 kHz sine with 5 ms raised-cosine edges. Invalid frequency shows an inline warning; invalid parameters disable generation. |
| Speech | Inline text, installed voice and speed controls; default system voice and rate 0.5, UI range 0.25–0.65. Render text into PCM for editing, not only live speech. Require nonempty text, at most 2,000 characters and 64,000 UTF-8 bytes. Support cancellation and a 60-second generation timeout; apply the duration/sample bounds above. Personal voices are excluded. |

Voice identifiers, installed assets and speech-rate scales are platform-specific. Speech does not request microphone permission or use an application-hosted remote service. The Android adapter must return PCM and report completion/errors/cancellation before replacing the source. See [audio implementation](AUDIO.md) and [porting boundaries](PORTING.md).

## Audio editing and playback

- Display source name, source-peak waveform and trim shading. The waveform does not draw processed gain/fade envelopes.
- Trim uses editable seconds and sliders, with `0 ≤ start < end ≤ source duration`; end is exclusive and a sub-sample selection retains at least one frame. Invalid ranges disable Play, Save and Export.
- Gain UI is −24…+24 dB in 0.5 dB steps. Normalize targets a 0.95 peak before gain; gain uses `10^(dB/20)`. Uniform headroom protection limits actual gain instead of clipping peaks; silence stays silent.
- Fade in/out is linear, 0…2 seconds in 0.01-second steps, capped at half the selection. Default fade is 0.02 s. Standard sources start at 0 dB with Normalize off.
- Speech starts with Normalize on and −6 dB gain, yielding about 0.476 peak before conversion. Preserve finite overrange speech PCM so the complete waveform can be scaled safely. Reset edits restores these speech defaults; other sources keep their own defaults.
- Full quality, the default preview mode, plays the edited source at 48 kHz. PicoFox mode narrows to 5 kHz before reconstruction to 48 kHz. Preview selection does not change export format.
- Provide Play/Pause/Resume, Stop, position/duration and seeking. Scrubbing pauses and resumes when it began during playback. Editing audio parameters or changing preview mode stops playback. Interruptions/removed audio routes pause; backgrounding stops playback and pending tone, speech and preview work.
- Render away from presentation work; cache unchanged previews up to 32 MB. Cancellation/generation tokens prevent a stale render or tone from starting playback or replacing a newer source. Transition fades reduce clicks. Physical first-audio latency is not measured.

Apple preview uses native `AVAudioConverter`; the portable DSP supplies the device renderer and a preview fallback. Both paths share the edit recipe. Device Save/Export always produces **5,000 Hz, mono, signed PCM16**, with a canonical metadata-free 44-byte WAV header and no trailing chunks. Resampling/encoding uniformly scales overload rather than flattening peaks. See [exact file layout](DEVICE-CONTRACT.md) and [DSP details](AUDIO.md).

## Restore default audio

Restore default audio requires confirmation. Load the bundled original 28.8-second recording; only its incorrect upstream WAV length fields were corrected. Factory audio starts with zero gain, Normalize off and no added fade; an unchanged export returns the exact bundled bytes. Retain AI6YM attribution and the CC BY-NC-SA 4.0 asset license.

Before replacing existing local audio, save exact Float32 samples, a native-rate PCM16 convenience WAV and a versioned recipe JSON in local backups. Failure to back up stops restoration. If an authorized folder is available, restoration also performs the normal backed-up/verified device audio save; otherwise it stays local. An unreadable existing device audio file or external change blocks direct replacement. Settings and firmware-generated ID files are untouched.

## Folder access, connection and saving

1. Obtain a folder capability through the platform's native picker. On iOS the user must first select the volume, commonly NO NAME; no unrestricted volume scan is available. Persist and resolve the offered capability, not a guessed path. Android should use the Storage Access Framework tree grant where supported.
2. Opening requires readable UTF-8 settings.txt, bounded to 64 KB. Snapshot its exact bytes, optional audio.wav (up to 12 MB), display name and permission handle. Audio read failure remains separate so settings can open; no arbitrary empty folder is populated.
3. While active, probe the authorized settings file every two seconds, skipping busy operations; macOS mount/unmount events also request a probe. Missing media, invalid/missing settings or lost permission mark the folder unavailable. This indicates access, not proven physical USB identity.
4. Disconnection keeps the snapshot and local edits and disables direct saves. Availability returning never reloads edits. Automatic reopening may load a saved folder only into an untouched editor; Close folder suppresses reopening for that session and retains edits.
5. Save only settings.txt or audio.wav. Resolve permission, coordinate/serialize I/O, and compare current destination bytes with the opened or last-saved bytes. Unexpected modification, creation or deletion is a conflict; retain edits and require deliberate reload.
6. Back up any existing destination to local application data before replacing it. Backup/read failure stops the write. Replace atomically, read back and compare exact bytes; update the expected snapshot only after success. An uncertain write needs deliberate recovery; no automatic rollback is promised.

Settings and audio saves are independent, not a transaction. Do not modify `.callsign.wav` or `.settings_crc.bin`, store backups/drafts on the radio, reformat/repair FAT, flash firmware or claim to eject hardware. The user disconnects USB and power-cycles PicoFox for settings/audio to take effect. See [Apple file access](APPLE-FILE-ACCESS.md) and [save lifecycle](ARCHITECTURE.md).

## Persistence and implementation boundaries

The current settings draft is explicit local JSON in application data; startup restores it. The folder permission handle persists separately. Audio, trim/gain/fade recipe, source style, playback state and creator fields are session state, not a general saved project or crash-recovery contract. Restore backups and original device-file backups persist locally; ordinary edits do not automatically create an audio project. Multiple Mac windows share one session.

Reuse or port the Foundation-only core's settings schema/text handling, power math, mono audio model, WAV decoder, DSP, factory asset and conformance fixtures. Replace SwiftUI/Observation, security-scoped bookmarks/coordination, AVAudioFile, AVAudioConverter, recording/playback and speech rendering with native Android adapters. Preserve behavior and byte contracts rather than Apple object types. Optional transport extensions are separate from this delivered file workflow; see [porting boundaries](PORTING.md).

## Acceptance status and remaining work

The Apple suite reports 80 passing tests, two optional checks skipped, 82 total. Version 1.0.7 build 8 was installed/launched on physical iPhone; simulator and Mac input/validation checks were exercised. These results do not certify an Android implementation.

Hardware integration must be qualified on the target operating system and device. See [verification checklist](VERIFICATION.md).
