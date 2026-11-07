# Source provenance

PicoFox is the work of AI6YM. References inspected October 20, 2026:

- https://github.com/ai6ym/PicoFox
- Firmware baseline c69af3a6079e42637678bccb91373134535c4ce6
- https://store.ai6ym.radio/pages/picofox

The upstream repository declares Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International: https://creativecommons.org/licenses/by-nc-sa/4.0/ . See its LICENSE for the complete notice and terms. Upstream directs commercial inquiries to its author.

This delivery contains a new companion implementation, protocol observations, synthetic test fixtures, and the original PicoFox factory recording for the Restore default audio action. It does not bundle upstream firmware binaries, source code, PCB files, or artwork. PicoFox/AI6YM references identify compatibility, not endorsement.

## Factory recording

`Sources/PicoFoxCore/Resources/factory-audio.wav` is the original 28.8-second recording by AI6YM / Giorgi Enterprises LLC, from [PicoFox audio.h](https://github.com/ai6ym/PicoFox/blob/c69af3a6079e42637678bccb91373134535c4ce6/PicoFox-Firmware/audio.h), firmware commit c69af3a6079e42637678bccb91373134535c4ce6. Its 288,000 PCM bytes are unchanged. Four WAV-header bytes were corrected to describe the actual 288,044-byte file.

The recording is provided under Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International. The upstream license is included at `Sources/PicoFoxCore/Resources/PICOFOX-LICENSE.txt` and is bundled with the recording. This notice does not assert broader licensing or commercial distribution rights for upstream material. The original FoxProgrammer source code is licensed under GNU GPL version 3. The factory recording is a separate asset under its upstream license; it is not relicensed under GPLv3.
