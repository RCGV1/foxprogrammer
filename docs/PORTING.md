# Porting to Linux, Windows and Android

Keep the product at two screens: **Settings** and **Audio**. Connection selection is an action within Settings, not an additional dashboard or onboarding flow. Documentation remains outside the app. Keep device files as the platform-neutral boundary.

The [current app specification](APP-SPEC.md) and [Android implementation handoff](ARCHITECTURE.md) define feature parity and native Kotlin/Compose boundaries. Keep optional USB serial transport/device control separate from filesystem storage. Published firmware supports diagnostics but no reboot/reload command; [serial findings](SERIAL-CONTROL.md) document the evidence and requirements for a future verified control profile.

## Reusable parts

PicoFoxCore imports Foundation only. Settings parsing, validation, edit math, chunk decoding, waveform peak calculation and canonical WAV serialization have no SwiftUI/AVFoundation dependencies. The package declares Apple minimums but has no Apple-only code in those sources. Linux/Windows compilation has not been tested in this delivery. Where using Swift is impractical, reimplement the documented contracts and use the JSON/WAV fixtures plus tests as conformance targets.

`WaveAudio.tone` generates a sine wave at 48 kHz by default, with frequency 100–2000 Hz and duration 0.1–60 seconds. Recording, imported audio, tones and generated speech all become the same mono PCM source. Apply the same trim, gain, normalization and fade recipe to every source; device export remains canonical 5 kHz mono PCM16 WAV.

Do not export a Swift object graph as a long-term interchange contract. Device files (`settings.txt`, `audio.wav`) are already portable. Version any future profile/session JSON independently from device firmware. The current `draft.json` is an internal implementation detail.

## Adapter contract

| Operation | Required behavior |
|---|---|
| Select folder | Return an OS-authorized capability, not a guessed global path |
| Open snapshot | Read settings bytes, optional audio bytes, display name and persisted permission handle |
| Import audio | Bound file size and decoded samples; decode supported platform formats into mono PCM and surface permission/format errors |
| Reopen | Resolve capability; fail on missing/revoked device rather than recreating an unrelated folder |
| Save one file | Restrict names, compare expected bytes, back up original locally, replace, verify bytes |
| Recording | Request microphone permission on demand, record local WAV, decode into the same source/editor, stop on background/interruption |
| Generate speech | Render text into bounded mono PCM for editing/export; support installed voice selection and cancellation, retaining the existing source on failure |
| Playback | Play 48 kHz audition PCM; offer full-quality/device-bandwidth modes, pause/resume/seek, transitions and interruption handling |
| Export | Let the user choose destination/name through native platform UI |
| Draft storage | Local application data; no extra files on PicoFox |
| Close | Release capability, retain local edits, do not pretend to eject hardware |

Actor serialization on Apple corresponds to a mutex or single-operation queue elsewhere. Back up each file separately; do not claim that two saves form a transaction. Where atomic replacement is unsupported, stop with a clear error unless an explicit, tested storage policy is added. Never silently truncate the live device file.

Apple's `AudioImport` adapter uses `AVAudioFile` for WAV and platform-supported MP3, M4A, AIFF and other audio. Other platforms need their own decoder; the portable core's decoder handles uncompressed PCM/float WAV. Keep imports within 64 MB, ten minutes and 12 million decoded mono samples. Decode completely before replacing the editor source.

`AudioPreview` uses `AVAudioConverter` for efficient Apple playback conversion. The portable DSP in `WaveAudio.previewWAV` provides a fallback: full-quality audition converts to 48 kHz; PicoFox audition narrows to 5 kHz before returning to 48 kHz for playback. Preview conversion may use a platform implementation, while device export uses the portable renderer and its WAV conformance contract.

`SpeechAudio` uses `AVSpeechSynthesizer.write` to collect PCM, rather than only speaking through the speakers. A port needs a synthesis API that returns audio buffers, bounded to ten minutes and 12 million mono samples, with completion, timeout and cancellation handling. Voice identifiers and rate scales are platform-specific; do not treat an Apple voice identifier as a portable preset. Cancelled or failed synthesis must leave the previous editor source intact.

## Platform map

| Area | Linux | Windows | Android |
|---|---|---|---|
| Native UI | GTK/libadwaita or Qt | WinUI/Windows App SDK | Kotlin + Jetpack Compose |
| File selection | Native portal/file chooser for sandboxed packages | Native folder picker; retain access as required by packaging model | Storage Access Framework `ACTION_OPEN_DOCUMENT_TREE` |
| Persistent permission | Portal grant or reselect mounted folder | FutureAccessList/token where applicable; otherwise explicit reopen | Persist offered read/write URI permission; handle revocation |
| File I/O | Filesystem APIs; removable-volume errors | File APIs with sharing/removal errors | ContentResolver/DocumentsContract on tree/document URIs |
| Audio | Platform player or GStreamer | Media Foundation or platform playback | AudioTrack/MediaPlayer using rendered PCM/WAV |
| Local state | XDG application data | Local application data | App-private files |

Android may expose the radio through a DocumentsProvider, but that must be tested. A document-tree URI is not a filesystem path, and providers vary in rename/replace/free-space support. If the device does not appear in SAF, adding USB Host + mass-storage + FAT access would be a separate, substantial transport implementation. Do not assume a generic USB permission supplies filesystem support.

## Port sequence

1. Run settings/WAV conformance vectors, malformed-input tests and resampler pass/reject tests on the new core.
2. Implement an in-memory storage fake and local-directory adapter; verify save conflicts/backups/errors before removable media.
3. Build the same two screens with native controls, no added marketing/guide screens.
4. Add platform import, speech synthesis, playback and export; all sources must use the same edit recipe and device-output conformance rules.
5. Test persisted permissions, revoked access and unplugging with actual PicoFox r2/r3 hardware.
6. Test actual firmware playback and settings application after reconnect/power cycle.

## Firmware profiles

The current compatibility profile is c69af3a. Changing callsign length, frequency margin, tone limits, timing interpretation or WAV layout requires a new profile and fixtures. There is no firmware-version discovery in the current file transport. The user-selected folder does not prove hardware revision or firmware identity.

Speech defaults use peak normalization followed by −6 dB gain (approximately 0.476 peak before conversion). Preserve finite overrange PCM from the speech renderer, then apply one uniform scale; hard-clamping each callback destroys waveform peaks. Reset restores these speech defaults, while imported/recorded/tone sources retain their ordinary defaults.
