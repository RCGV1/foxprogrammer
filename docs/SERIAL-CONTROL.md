# Serial control extension

The shipped Apple app uses selected-folder access to `settings.txt` and `audio.wav`. It has no serial command sender or restart control. The file-format baseline is firmware [c69af3a](https://github.com/ai6ym/PicoFox/tree/c69af3a6079e42637678bccb91373134535c4ce6). That baseline emits serial diagnostics at 115200 baud but has no application command parser or normal-reboot command. These observations do not identify a connected device's firmware.

Keep three interfaces independent in future ports:

| Interface | Responsibility |
|---|---|
| DeviceStorage | Folder/provider grants, snapshots, backups, guarded saves and availability |
| SerialTransport | Explicit USB access, CDC interface selection, bounded byte I/O, timeouts, cancellation and detach |
| DeviceControl | A documented firmware profile, capability discovery, framing, acknowledgement and errors |

Unknown firmware must report restart/reload as unsupported. Do not send guessed commands. A CDC interface does not establish a control protocol, and a folder grant does not identify a CDC device.

The 1200-baud touch in the upstream TinyUSB stack enters the bootloader; it is not a normal application restart. Do not use it as Apply Changes. Before adding supported device control, document command bytes, response semantics and exact firmware versions; test partial reads, malformed responses, timeouts, duplicates and detach with a fake transport. Finish and verify file writes, close storage resources and establish safe storage ownership before any supported restart.

See [porting boundaries](PORTING.md).
