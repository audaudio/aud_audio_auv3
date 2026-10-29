# The AUv3 of an app

What an app hands `aud_audio_auv3` to build an Audio Unit v3 of its own
(ticket 64, plugin-011): one configuration, one graph document and its
presets. The shell is generic; everything that makes the unit an instrument
of the app lives in these three files. `aud_audio_plugin` reads them; its
`doc/plugin-config.md` describes the keys every shell shares, this file adds
the AUv3's identity, its build and how an app's extension target takes it.

## plugin.json

The shared keys of `aud_audio_plugin`, plus the identity and an `auv3`
section:

```jsonc
{
  "schema": 1,
  "name": "Aud Example",               // the unit's name in a host
  "vendor": "audaudio",                // shown as "<vendor>: <name>"
  "version": "0.2.0",                  // the AudioComponents version
  "bundleId": "com.example.audAudioAuv3Example", // the subsystem of the unit's log
  "packages": [],
  "document": "document.json",
  "presets": "presets.json",
  // The content inside the extension (macOS, then iOS): the sandbox lets
  // an extension read its own bundle, not the app around it.
  "content": ["bundle:Contents/Resources/content/sfz", "bundle:content/sfz"],
  "parameters": [{ "node": "filter", "param": "cutoff", "name": "Cutoff" }],
  "controls": [{ "id": "slider", "name": "Slider", "channel": 0, "cc": 74 }],
  "auv3": {
    // The component's codes: hosts store them in every project, so they
    // never change; Apple reserves codes of lower-case letters only.
    "type": "aumu",
    "subtype": "AExm",
    "manufacturer": "Demo",
    "description": "The example of aud_audio_auv3",
    "tags": ["Synthesizer"],
    // The sample cache of the extension process, shared by all instances
    // of a host, in megabytes.
    "cacheBudgetMB": { "macos": 256, "ios": 96 },
    // The Dart entry point of the editor inside the extension; without
    // one the unit has no editor.
    "editorEntrypoint": "auv3EditorMain"
  }
}
```

## The build

```bash
node scripts/build-plugin.js --config <plugin.json> \
  --package-config <app>/.dart_tool/package_config.json \
  --platform macos --platform ios --platform ios-simulator --out <out>
```

```text
<out>/macos/libaud_auv3.a          the shell, core, graph and node packages
<out>/ios/libaud_auv3.a
<out>/ios-simulator/libaud_auv3.a
<out>/Info.plist                   the extension's, with AudioComponents
<out>/AudAuv3.xcconfig             what the extension target includes
<out>/aud_plugin/                  plugin.json, document, presets
```

The xcconfig links the library of the platform with `-force_load`, the
system frameworks and Flutter, exports the four functions of
`src/aud_auv3_editor_api.h` (`STRIP_STYLE = non-global` keeps them), sets
`INFOPLIST_FILE`, the run paths to Flutter of the app and
`AUD_AUV3_PLUGIN_FOLDER`.

## The app's extension target

An app extension target per platform, product type `app-extension`, with
no code of its own: one empty source (Xcode links a target only with a
source), and a base configuration of the app that includes Flutter's and
the shell's settings and takes the app's versions, which an extension must
share:

```text
#include "../Flutter/Generated.xcconfig"
#include "<out>/AudAuv3.xcconfig"
MARKETING_VERSION = $(FLUTTER_BUILD_NAME)
CURRENT_PROJECT_VERSION = $(FLUTTER_BUILD_NUMBER)
```

- The extension target copies `$AUD_AUV3_PLUGIN_FOLDER` into its bundle as
  `aud_plugin` (and the content its `content` names).
- The app target embeds the extension in a phase "Embed Foundation
  Extensions" that comes before Flutter's own run script, or Xcode reports
  a cycle.
- On macOS the app target copies its `App.framework` into the
  extension's `Frameworks` after Flutter embedded it and signs the
  framework and the extension again: the App Sandbox lets the extension
  read only its own bundle. On iOS the extension takes the app's
  `App.framework` from the app's `Frameworks`, as it takes Flutter: the
  App Store refuses an iOS extension with a `Frameworks` folder of its own
  (ITMS-90206).
- On iOS the app's App ID carries the Inter-App Audio capability: without
  it the system does not register the extension.
- The extension and the app share a team: the extension runs with the
  hardened runtime and loads only code of its team.

`example/ios` is such an app; `scripts/build-plugin.js --appex` builds the
same for macOS without Xcode, for the package's tests.

## What the unit does

`src/aud_auv3_audio_unit.h`: parameters (`preset`, `<node>_<param>`,
`control_<id>`), factory presets, `fullState` with the shell's state under
`aud_state`, the host's MIDI 1.0 and UMP events and scheduled parameter
changes at their sample offsets, the host's musical context and transport
state, offline rendering that waits for a preset to load.

## The editor

`src/aud_auv3_view_controller.mm` starts Flutter inside the extension when
the view appears - one `FlutterEngineGroup` per process on iOS, an engine
per view on macOS - at `editorEntrypoint` with the argument
`--aud-auv3-instance=<n>`. The editor connects with `AudAuv3Shell`
(`lib/`), says hello and speaks the shell protocol of `aud_audio_plugin`
through `dart:ffi`: the welcome, preset choices, its MIDI and its settings;
the notes it holds end when its view goes.
