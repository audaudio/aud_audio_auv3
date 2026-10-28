# aud_audio_auv3

English | [Deutsch](README.de.md)

Audio Unit v3 extension of the Audanika Audio Engine over its headless
host.

The AUv3 shell (ticket 64, step S20) on macOS and iOS: an app configures it
with a `plugin.json`, a graph document and its presets and gets an Audio
Unit extension with the app's sound and the app's own Flutter UI as its
editor. Part of the Audanika Audio Engine; planned in
[aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Motivation

An app that plays its sound through the engine wants that sound in an
Audio Unit host such as Logic Pro, GarageBand or Loopy Pro too, without
writing the extension itself. This package is the AUv3 format of the
engine: the format-agnostic core - the engine over the headless host, the
configuration, presets, state, MIDI events, transport and the shell
protocol - comes from `aud_audio_plugin`; this package adds the
`AUAudioUnit`, the editor inside the extension and the build of the
static library an app's extension target links.

## Installation

The package is not published to pub.dev; add it as a git dependency:

```yaml
dependencies:
  aud_audio_auv3:
    git:
      url: git@github.com:audaudio/aud_audio_auv3.git
      tag_pattern: "{{version}}"
    version: ^0.2.1
```

## Usage

The editor runs inside the extension: the view controller starts it at a
Dart entry point with the instance of its unit, and the editor talks to
the unit through `AudAuv3Shell` with `dart:ffi`, in the shell protocol of
`aud_audio_plugin`. From `example/lib/main.dart`:

```dart
/// The editor inside the extension: the view controller starts it with
/// the instance of its unit, it talks to the unit with dart:ffi
/// ([AudAuv3Shell]).
@pragma('vm:entry-point')
void auv3EditorMain(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final instance = AudAuv3Shell.instanceOf(arguments);
  if (instance == null) {
    runApp(const _Page(child: Text('No unit')));
    return;
  }
  runApp(_Editor(shell: AudAuv3Shell.connect(instance)));
}
```

The example (`example/`) is the unit "Aud Example" of the graph's own
nodes, its container app for macOS and iOS and an editor with its presets
and four keys. The unit is built from the example's `plugin.json`, then
the container app is built and installed with Xcode:

```bash
node scripts/build-plugin.js --config example/plugin/plugin.json --platform ios
```

The project names no team, so build `example/ios` under your own, e.g.
`xcodebuild … DEVELOPMENT_TEAM=<team>`; its App ID needs the Inter-App
Audio capability. The unit then plays in an Audio Unit host.

## Limitations

- macOS (arm64) and iOS, the simulator included; no other platform
- The extension's target holds no code of its own: the unit, the editor
  and the build come from this package, the sound and the UI from the app
- Flutter (BSD-3-Clause) travels in the extension; `flutter build` writes
  its notices and those of every Dart package into
  `App.framework/flutter_assets/NOTICES.Z`

## Documentation

- [doc/plugin-bundle.md](doc/plugin-bundle.md): what an app hands the
  package to build an Audio Unit of its own - the `plugin.json`, the
  graph document, the presets and the extension target
- The guides in [doc/guides](doc/guides) and the blog posts in
  [doc/blog](doc/blog)
- The changes per version in [CHANGELOG.md](CHANGELOG.md)

## How it works

- The unit (`src/aud_auv3_audio_unit.h`): an `AUAudioUnit` over the
  engine of `aud_audio_plugin` - parameters, factory presets, `fullState`
  with the editor's settings, whose change notifies the host, the host's
  MIDI and transport, offline rendering, the editor's notes as the MIDI
  output "MIDI Out", and a render meter in the system log every 2 s.
- The editor (`src/aud_auv3_view_controller.mm`,
  `src/aud_auv3_editor_bridge.h`): Flutter inside the extension, which
  talks to the unit with `dart:ffi` (`src/aud_auv3_editor_api.h`) in the
  shell protocol of `aud_audio_plugin`.
- The build (`scripts/build-plugin.js`): a static library per platform
  (macOS arm64, iOS, the simulator), the extension's `Info.plist` and an
  xcconfig for an app's extension target, which holds no code of its own.
- Dart (`lib/`): `AudAuv3Shell`, the editor's end of the protocol.

## Status

Before 1.0 - the API may change between minor versions.

## Contributing

Tickets run through the `gg` workflow: see the
[Develop Guide](doc/guides/develop-guide.md) and the
[Review Guide](doc/guides/for-ai/ai-review-guide.md). Build and test:

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

## License

MIT - see [LICENSE](LICENSE).
