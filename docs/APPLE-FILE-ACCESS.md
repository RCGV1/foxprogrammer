# Apple folder permissions and hardware access

The app uses SwiftUI `fileImporter` with `UTType.folder`. Apple grants access to the selected folder through a security-scoped URL. A general USB permission or private filesystem entitlement is not required for this workflow. It depends on the operating system exposing PicoFox as a mounted volume.

[Apple’s directory-access documentation](https://developer.apple.com/documentation/uikit/providing-access-to-directories) describes folder capabilities, start/stop access, file coordination and bookmarks. [Apple’s external-storage guide](https://support.apple.com/guide/iphone/iph95baac91f/ios) describes connectors, supported formats, and possible external power requirements. These explain the supported application route; they do not certify PicoFox compatibility.

## iOS and iPadOS

- Minimum deployment: 17.0.
- Pick an existing folder with the system document picker; never scan `/Volumes` or guess a raw filesystem path.
- First connection: tap Browse in the picker, return to Locations if it is inside On My iPhone, select the mounted PicoFox volume (often NO NAME), then Open. Recents and Shared are file-picker categories, not lists of connected drives. Apple explicitly recommends tapping Browse again if Locations is not visible.
- Start scoped access before each operation and stop it afterward if acquired.
- Use `NSFileCoordinator` for external reads/writes, including imported WAV files.
- Persist minimal bookmark data, not a path string. Resolve with `.withoutUI` and reject stale bookmarks.
- `LSSupportsOpeningDocumentsInPlace` is enabled. File sharing is enabled for the app’s Documents directory; backups/drafts in Application Support remain private and are not exposed by that flag.
- Recording requests microphone permission only after Record is pressed, via AVAudioApplication. NSMicrophoneUsageDescription explains that audio creates a PicoFox WAV. Recording uses AVAudioSession playAndRecord; preview uses playback. No Bluetooth, location, local-network, MFi/ExternalAccessory, or USB entitlement is requested.
- The user can revoke folder access. Errors are surfaced; select the folder again.
- Once permission is saved, the app can initially reopen that folder into an untouched session. Existing drafts/audio and an explicit **Close folder** suppress automatic reopening.
- Initial iOS/iPadOS access still requires user-granted folder selection. [`FileManager.mountedVolumeURLs`](https://developer.apple.com/documentation/foundation/filemanager/mountedvolumeurls(includingresourcevaluesforkeys:options:)) returns nil outside macOS; the app does not discover unknown USB volumes by scanning private paths. A saved bookmark allows retries of the already authorized folder.

## macOS

- Minimum deployment: 14.0; native SwiftUI/AppKit build, not Catalyst.
- App Sandbox is enabled with `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`. Microphone recording also uses `com.apple.security.device.audio-input`, NSMicrophoneUsageDescription and AVCaptureDevice authorization.
- Bookmarks use `.withSecurityScope` when created and resolved. Other behavior matches the iOS adapter.
- While the scene is active, `NSWorkspace.shared.notificationCenter` mount/unmount notifications trigger an immediate availability check. Apple documents that [unmount notifications](https://developer.apple.com/documentation/appkit/nsworkspace/didunmountnotification) include sudden removal.
- The unsigned test build validates local coordination, backup and conflict logic, but does not prove App Sandbox permission behavior. A signed app and physical folder-picker test are required for that claim.

## Availability checks

While the scene is active, a serialized loop checks the saved folder capability and reads/parses `settings.txt` every two seconds. Probes pause during busy operations and stop when the scene becomes inactive. They do not read audio, change device files, or reload editor contents.

A failed check marks the selected folder unavailable and disables direct saves. The snapshot, settings, audio and edits remain intact; a successful later check restores availability without replacing them. Unavailable can mean removed media, missing/invalid settings, expired permission or another access failure. It is not proof of physical USB disconnection. Actual writes still perform conflict and read-back checks.

Routine successful operations and availability transitions do not produce success banners. Actual operation errors and confirmations for replacing edits remain. Restoring factory audio while the known folder is unavailable affects only the local editor and its local recovery backup.

## Connection troubleshooting

1. Check the power switch and USB data cable; charging alone does not prove data connectivity.
2. Verify the device volume appears under Locations in Files/Finder. Try a suitable powered adapter/hub if necessary. Lightning and USB-C hardware differ.
3. Check that settings.txt exists. The app intentionally requires it before enabling direct folder saves.
4. Select the **folder**, not just the text file. This grants access to both settings and audio.
5. Access to a previously selected folder is retried automatically while active. Reselect if permission has expired. A cached folder name is not evidence that hardware remains connected.
6. If the volume never mounts, stop troubleshooting app permissions. Investigate the device’s mass-storage presentation, cable, power and host compatibility. Do not reformat its firmware-managed flash.

## Write and recovery boundaries

Scope acquisition and filesystem access may fail independently. The adapter allows ordinary app-owned/local URLs (which do not require a scope) and reports actual read/write errors. Actor serialization prevents two app saves racing. NSFileCoordinator covers cooperative access; byte comparisons detect most outside edits since opening.

Atomic replacement may require free space for a temporary file. Filesystem failures are reported without an unsafe in-place fallback. Read-back confirms what the OS returned, not long-term flash persistence or the firmware’s later interpretation. If an unplug interrupts a save, reconnect and inspect the files before transmitting. Originals are in Application Support/PicoFox/Backups. System export has its own OS overwrite flow and bypasses the direct-save backup/conflict pipeline.

Recording API reference: [Apple microphone permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)), [microphone usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription). No audio leaves the device except through an explicit export or device-file save.
