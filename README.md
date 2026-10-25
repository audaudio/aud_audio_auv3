# aud_audio_auv3

Audio Unit v3 shell of the Audanika Audio Engine over its headless host.

Part of the Audanika Audio Engine; planned in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## What the package holds (ticket 64)

The AUv3 shell (step S20) on macOS and iOS: an app configures it with a
`plugin.json`, a graph document and its presets and gets an Audio Unit
extension with the app's sound and the app's own Flutter UI as its editor
([doc/plugin-bundle.md](doc/plugin-bundle.md)).

- **The unit** (`src/aud_auv3_audio_unit.h`): an `AUAudioUnit` over the
  engine of `aud_audio_plugin` - parameters, factory presets, `fullState`
  with the editor's settings, whose change notifies the host, the host's
  MIDI and transport, offline rendering, the editor's notes as the MIDI
  output "MIDI Out", and a render meter in the system log every 2 s.
- **The editor** (`src/aud_auv3_view_controller.mm`,
  `src/aud_auv3_editor_bridge.h`): Flutter inside the extension, which
  talks to the unit with `dart:ffi` (`src/aud_auv3_editor_api.h`) in the
  shell protocol of `aud_audio_plugin`.
- **The build** (`scripts/build-plugin.js`): a static library per platform
  (macOS arm64, iOS, the simulator), the extension's `Info.plist` and an
  xcconfig for an app's extension target, which holds no code of its own.
- **Dart** (`lib/`): `AudAuv3Shell`, the editor's end of the protocol.
- **The example** (`example/`): the unit "Aud Example" of the graph's own
  nodes, its container app for macOS and iOS and an editor with its
  presets and four keys.

## Build and test

```bash
dart pub get
node scripts/test-native.js
dart test
node scripts/host.js --sign "<identity>" --validate
```

`test-native.js` runs the native unit tests of `test/native`. `host.js`
builds the example's container app with its extension for macOS, registers
it and runs the test host `test/host/aud_auv3_host.swift`, which loads the
unit out of process as Logic Pro does: presets, rendering, state, two
instances, realtime blocks, the MIDI output and the editor; `--validate`
runs `auval` too, `--play <seconds>` plays live in the realtime mode.

On iOS: `node scripts/build-plugin.js --config example/plugin/plugin.json
--platform ios`, then build and install `example/ios` with Xcode; its App
ID needs the Inter-App Audio capability.

Flutter (BSD-3-Clause) travels in the extension; `flutter build` writes its
notices and those of every Dart package into
`App.framework/flutter_assets/NOTICES.Z`.
