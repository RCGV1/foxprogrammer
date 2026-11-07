# FoxProgrammer

A community project for **AI6YM PicoFox** settings and audio, built with native SwiftUI for iPhone, iPad and Mac.

[Download on the App Store](https://apps.apple.com/app/id6828721649) · [Support](https://rcgv1.github.io/foxprogrammer/support.html) · [Privacy](https://rcgv1.github.io/foxprogrammer/privacy.html)

## Features

Two screens keep the workflow compact:

- **Settings:** callsign, frequency, duty cycle, Morse ID and a calculated power slider. Export `settings.txt` or save to a selected PicoFox folder.
- **Audio:** record, import, create a custom tone or render speech with system voices. Play, trim, adjust gain, normalize and fade, then export a compatible WAV. Restore the factory recording or a backup.

Edits run locally. No account, analytics or cloud backend is required. Direct device saves include original-file backups, conflict checks and read-back verification. The app retains edits when the selected drive becomes unavailable.

## Connect PicoFox

1. Connect a powered PicoFox with a USB data cable and any required adapter.
2. Confirm its drive appears in Finder on Mac or **Files → Browse → Locations** on iPhone/iPad.
3. In FoxProgrammer, choose **Files → Open PicoFox folder** and select the folder containing `settings.txt`.
4. Edit and save settings or audio. Eject through the operating system when available, disconnect USB and power-cycle the radio to apply changes.

The system must mount the drive before the app can access it. iPhone/iPad require an initial folder selection; the app cannot bypass Apple's file permissions. Audio creation and file export work without hardware.

Power is an approximate calculation for PicoFox r3, not a calibrated RF measurement. Check your hardware revision, firmware and operating privileges. The current file contract targets the firmware baseline documented below; newer firmware fields are preserved but may not have dedicated controls. Folder access does not identify the installed firmware.

## Build

Requires **Xcode 26+**, iOS/iPadOS **17+**, or macOS **14+**. There are no third-party runtime dependencies.

Open `PicoFox.xcodeproj`:

| Scheme | Target |
|---|---|
| `PicoFox` | iPhone and iPad |
| `PicoFoxMac` | Native macOS development build |
| `PicoFoxMacStore` | Native Mac App Store archive using the shared store bundle ID |

Choose your signing team for physical devices or distribution. Development Mac builds use `app.picofox.studio.mac`; the store configuration uses `app.picofox.studio` for the shared App Store listing. Each has its own sandbox data.

The checked-in Xcode project can be regenerated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
swift test
```

Run Apple adapter tests with the `PicoFoxMac` scheme's Test action. Tests use temporary local folders; physical drive compatibility, permission revocation and unplug-during-save behavior also need device testing.

## Architecture and ports

`Sources/PicoFoxCore` contains portable settings parsing, validation, power calculations, PCM/WAV processing and conformance tests. `App/Services` adapts Apple file access, audio playback/import/recording and speech. `App/Views` contains SwiftUI presentation.

- [Component map and architecture](docs/ARCHITECTURE.md)
- [PicoFox settings and WAV contract](docs/DEVICE-CONTRACT.md)
- [Audio processing](docs/AUDIO.md)
- [Apple folder access](docs/APPLE-FILE-ACCESS.md)
- [Linux, Windows and Android porting boundaries](docs/PORTING.md)
- [Serial transport extension](docs/SERIAL-CONTROL.md)

`Fixtures/` supplies synthetic examples and language-neutral conformance vectors. Future ports should keep storage access and serial control separate. The app currently has no serial reboot, firmware-flashing or filesystem-repair feature.

## Contributing

Use [GitHub Issues](https://github.com/RCGV1/foxprogrammer/issues) for bugs and feature requests. Include the app version, operating system and reproduction steps; keep recordings, callsigns and device backups private. For code changes, include relevant tests and document file-format or platform behavior changes. Contributions are accepted under the project's GPLv3 source license.

## License and attribution

Original FoxProgrammer source code is **GNU GPL version 3** (`GPL-3.0-only`); see [LICENSE](LICENSE). Copyright © 2026 Benjamin Faershtein.

The bundled factory recording is a separate asset by **AI6YM / Giorgi Enterprises LLC**, licensed **CC BY-NC-SA 4.0**. Its PCM samples are unchanged; WAV length fields were corrected. That asset is not covered by GPLv3. See [NOTICE.md](NOTICE.md) and the [upstream asset license](Sources/PicoFoxCore/Resources/PICOFOX-LICENSE.txt).

[PicoFox](https://github.com/ai6ym/PicoFox) is an AI6YM product. Hardware names identify compatibility. FoxProgrammer is a community project.
