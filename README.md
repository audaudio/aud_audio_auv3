# aud_audio_auv3

Audio Unit v3 extension of the Audanika Audio Engine over its headless host.

Part of the Audanika Audio Engine; planned in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## What the package holds (0.1.0, ticket 24)

The iOS part of the spike S0-plugin-ui: an AUv3 extension with a Flutter
editor. Decision plugin-003 rests on its measurements; the shell itself is
step S20.

- The engine (`src/aud_auv3_engine.h`): a C API over the headless host of
  `aud_audio_graph` that renders the spike's graph document, with stable
  parameter ids and a meter. `scripts/build-engine.js` builds it as a
  static library for `iphoneos` and `iphonesimulator` into `build/ios`.
- `AudAuv3Component` (`lib/`): the component description, the channel
  names and the parameter ids that the extension, its editor and the
  container app share.
- The example (`example/`): the container app and the extension
  `AudSpikeAU`.
  - The extension: an `AUAudioUnit` with a parameter tree and a render
    block over the engine, and a ballast of 100 MB that stands in for the
    sampler. Its `AUViewController` shows a Flutter editor whose engines
    come from one `FlutterEngineGroup` and start when the view first
    appears; the knobs write the parameter tree.
  - The app loads one to four instances out of process, opens their
    editors and reports the extension's `phys_footprint` and the editors'
    first frames, once a second, on the screen and on stderr.

## Build and run

```bash
node scripts/build-engine.js
cd example
flutter build ios --release
xcrun devicectl device install app --device <id> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <id> --console \
  com.audanika.audAudioAuv3 -- --instances 2 --duration 600
```

The app's App ID needs the Inter-App Audio capability: without it, iOS
refuses to load the extension out of process
(`kAudioComponentErr_NotPermitted`).

Flutter (BSD-3-Clause) travels in the extension; `flutter build` writes its
notices and those of every Dart package into
`App.framework/flutter_assets/NOTICES.Z`.
