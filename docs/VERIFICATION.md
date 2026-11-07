# Verification

Run portable settings and DSP tests with `swift test`. Run the native adapter tests using the PicoFoxMac scheme in Xcode. File tests use temporary folders and cover backups, conflicts, unavailable files and verified writes.

Before distributing a change, build the affected Apple targets and exercise Settings and Audio at small window sizes and with large text. Check generated tones, speech, imports, recording, trims, gain, fades, playback and exported WAV data.

Hardware qualification should cover folder selection, saved grants, revoked grants, reconnect, external file changes, full media, unplug during save, backup recovery and firmware playback on each supported host and hardware revision. Simulator success does not establish physical USB compatibility.

RF power values are nominal calculations; measured calibration requires separate RF equipment and documented hardware conditions.
