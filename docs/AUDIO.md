# Audio implementation

`WaveAudio` is a portable sample model and DSP implementation. Apple recording/playback live in `AudioCapture` and `AudioPlayback`; `AudioPreview`, `AudioImport` and `SpeechAudio` adapt Apple’s conversion, decoding and speech APIs.

## Restore default audio

The native Audio screen offers Restore default audio with a confirmation. Offline, it loads the original 28.8-second recording for playback, editing, and export. With a device folder open, it writes the bundled canonical WAV through the normal expected-bytes comparison, original-file backup, atomic replacement, and read-back verification. Existing unreadable audio or external changes block direct replacement. Settings and Morse ID files are untouched.

`FactoryAudio.wavData()` reads the recording from a SwiftPM resource bundle, so future ports can reuse the asset and its provenance. All audio payload samples match upstream; only incorrect WAV length fields were corrected. An untouched restored source exports the exact bundled bytes and starts with no added fade. Attribution and license are in NOTICE.md and the resource bundle.

Before replacing local editor audio, the app saves Application Support/PicoFox/Backups/<UUID> with `source.f32le` (exact original mono samples as little-endian IEEE 754 Float32), `source.wav` (native-rate PCM16 convenience copy), and `edits.json`. The JSON records version, sample encoding/rate/count, source name, trim bounds, gain, normalization and fade. The raw source plus recipe preserve the edit session without baking effects twice. Backup failure stops restoration before writing the device. A failed device save leaves the editor intact; read-back failures may require recovery from the saved original-file backup.

## Creation and import

Tone opens inline controls for frequency (100–2000 Hz) and duration (0.1–60 seconds). It creates a sine at 48 kHz with five-millisecond raised-cosine edges. The editable source remains at 48 kHz until device conversion is requested. The default is 600 Hz for three seconds.

Speech opens inline text, voice and speed controls. `AVSpeechSynthesizer.write(_:toBufferCallback:)` renders an utterance into PCM buffers, which are averaged to the same mono sample model. Successful generation loads the editor rather than merely reading text aloud. Play, trim, gain, fades, device save and export then use the normal pipeline. Speech starts with Normalize enabled and −6 dB gain: the normalized 0.95 peak is reduced to about 0.476 (approximately −6.45 dBFS) before conversion. Reset edits restores these speech-specific defaults. Raw finite overrange Float PCM is retained; capture does not flatten peaks before the editor can scale the whole waveform. A new request, cancellation, generation failure or timeout cannot replace the source with partial speech. Personal voices are excluded; no microphone permission or remote speech service is requested. Available voices depend on the operating system’s installed voice assets. Text is limited to 2,000 characters; decoded sample/duration limits also apply.

Apple references: [speech buffer rendering](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)), [available voices](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/speechvoices()).

Record requests microphone permission on demand and creates mono 44.1 kHz PCM16 WAV. Stop, the two-minute limit, backgrounding or interruption closes the file. Recorder delegates distinguish success from encoding failure. Interruptions finalize separately because AVAudioRecorder does not promise a finish callback for interruptions. Readable, nonempty recording frames are required before loading into the editor; failures remove the temporary file and show an error. The iOS recording session deactivates before handing over to playback.

Apple-platform import uses `AVAudioFile` with Float32 noninterleaved processing buffers to decode supported audio such as WAV, AIFF, MP3 and M4A/AAC. Scoped/coordinated file access surrounds decoding, with bounded reads and mono conversion. Imported audio uses the same trim/editor controls as recording, tone and speech. Protected media and formats unavailable to the system decoder can fail to import.

The portable WAV decoder accepts little-endian RIFF/WAVE, scans bounded chunks with odd-length padding, and supports PCM8/16/24/32 and IEEE float32. PCM8 is unsigned. Channels are averaged to mono; nonfinite samples are rejected. This mono policy can cancel opposite-phase stereo material. Preserving/selecting stereo channels is not implemented. [Apple file decoding documentation](https://developer.apple.com/documentation/avfaudio/avaudiofile/init(forreading:commonformat:interleaved:)).

Input limits remain 64 MB, 1–8 channels, 1–192 kHz, ten minutes and twelve million decoded mono frames. Internal rendering permits up to 32 million working samples so a ten-minute 5 kHz file can be previewed at 48 kHz. The portable decoder remains restricted to supported PCM/float RIFF/WAVE; other supported imports require the Apple adapter or an equivalent decoder in future ports.

## Non-destructive edits

Trim bounds are seconds, 0 ≤ start < end ≤ source duration; end is exclusive. A valid sub-sample selection keeps at least one frame. Gain uses 10^(dB/20); normalization targets 0.95 before gain. Peak protection caps the applied gain uniformly at the available headroom, preserving waveform shape instead of flattening peaks. Requested positive gain can therefore exceed the amount actually applied. Silence remains silence.

Linear fades apply at both ends, capped at half the selection. Resampling can overshoot between source samples; the encoder uniformly reduces the complete signal if needed instead of clipping those peaks. No dynamic compressor or loudness normalizer is used.

## Preview and export

- **Full quality** is the default. It auditions the edited source at a standard 48 kHz playback rate.
- **PicoFox** auditions the 5 kHz device bandwidth, reconstructed to 48 kHz for the audio output. Narrower sound in this mode is expected.
- Device save/export always creates 5,000 Hz, mono, signed PCM16 with the canonical metadata-free 44-byte header. It is independent of the preview selector.

Both paths share trim/gain/normalization/fades. Unchanged preview data is cached up to 32 MB, so Play does not repeatedly convert the same recipe. An operation token and task cancellation prevent Stop, backgrounding or source replacement from starting an old render later.

Apple preview resampling uses the native `AVAudioConverter` at maximum quality, with chunked input, end-of-stream flushing, cancellation and a bounded output size. This avoids running the portable Swift sinc inner loop for the complete selection before Play. Full-quality preview converts directly to 48 kHz; PicoFox preview converts to 5 kHz then reconstructs to 48 kHz. Device export continues to use the portable resampler. The device build uses Release optimization. [Apple converter documentation](https://developer.apple.com/documentation/avfaudio/avaudioconverter).

`AudioPlayback` uses AVAudioPlayer with real completion/error callbacks and 40 ms position updates. It provides Play/Pause/Resume, Stop and seeking. Eight-millisecond fades at transitions reduce clicks. Per-player and per-resume tokens prevent delayed callbacks or fades from changing a replacement player. iOS interruptions and removed audio routes pause playback; session deactivation returns audio ownership when idle without interrupting a recording session.

## Resampling and encoding

The resampler is a DC-normalized, windowed-sinc filter. ratio = outputRate/inputRate, cutoff = min(1, ratio) × 0.94, radius = ceil(20/cutoff). A raised-cosine window bounds the kernel. Output count is max(1, round(inputCount × ratio)); input boundaries use the available weighted samples. Equal input/output rates bypass filtering.

Kernels are cached by fractional phase. Common sample-rate pairs use exact rational phases computed from the rates' greatest common divisor. Unusual rate pairs use bounded phase quantization, with at most one million cached coefficients. Cancellation is checked during kernel creation and every 4096 output frames.

`pcm16WAV()` encodes the current rate. `picoFoxWAV()` filters to 5 kHz then calls that encoder. `previewWAV(radio:)` selects full-band/device-band material then reconstructs to 48 kHz. PCM quantization rounds sample × 32767 to little-endian Int16 after uniform peak protection.

The waveform displays source peaks and trim shading; it does not draw processed gain/fade envelopes. Audio and edits remain in memory until saved/exported.

## Regression checks

AudioQualityTests checks 48 kHz tone frequency, smooth endpoints, harmonics, reconstruction of legacy 5 kHz tones, positive-gain distortion, preview bandwidth/duration, and encoder overload behavior. AudioPlaybackTests exercises a real AVAudioPlayer using silent PCM for pause/resume, seeking, completion, replacement and invalid data. StudioPlaybackTests covers pending-render cancellation/source replacement and both preview modes with compatible device exports. These tests do not measure the acoustic output of speakers or headphones.

Device audio is read independently from settings. A storage read failure leaves local editing available and disables direct audio replacement. For readable factory WAVs, decodePicoFox supports only the proven 288,044-byte factory file / 300,044-byte declared-length mismatch in a memory copy; ordinary WAV imports remain strict. See DEVICE-CONTRACT.md for exact guards.
