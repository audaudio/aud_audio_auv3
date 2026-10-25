# aud_audio_auv3

Audio-Unit-v3-Hülle der Audanika Audio Engine über ihrem Headless-Host.

Teil der Audanika Audio Engine; geplant in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Was das Paket enthält (Ticket 41)

Die AUv3-Hülle (Schritt S20) auf macOS und iOS: Eine App konfiguriert sie
mit einer `plugin.json`, einem Graph-Dokument und dessen Presets und erhält
eine Audio-Unit-Erweiterung mit dem Klang der App und der eigenen
Flutter-Oberfläche der App als Editor
([doc/plugin-bundle.md](doc/plugin-bundle.md)).

- **Die Unit** (`src/aud_auv3_audio_unit.h`): eine `AUAudioUnit` über der
  Engine von `aud_audio_plugin` - Parameter, Werks-Presets, `fullState`
  mit den Einstellungen des Editors, deren Änderung den Host benachrichtigt,
  MIDI und Transport des Hosts, Offline-Rendering, die Noten des Editors
  als MIDI-Ausgang „MIDI Out" und eine Render-Messung alle 2 s im
  Systemprotokoll.
- **Der Editor** (`src/aud_auv3_view_controller.mm`,
  `src/aud_auv3_editor_bridge.h`): Flutter innerhalb der Erweiterung, das
  mit `dart:ffi` (`src/aud_auv3_editor_api.h`) im Shell-Protokoll von
  `aud_audio_plugin` mit der Unit spricht.
- **Der Build** (`scripts/build-plugin.js`): eine statische Bibliothek je
  Plattform (macOS arm64, iOS, der Simulator), die `Info.plist` der
  Erweiterung und eine xcconfig für das Erweiterungs-Target einer App, das
  keinen eigenen Code enthält.
- **Dart** (`lib/`): `AudAuv3Shell`, das Ende des Protokolls im Editor.
- **Das Beispiel** (`example/`): die Unit „Aud Example" aus den eigenen
  Knoten des Graphen, ihre Container-App für macOS und iOS und ein Editor
  mit ihren Presets und vier Tasten.

## Bauen und testen

```bash
dart pub get
node scripts/test-native.js
dart test
node scripts/host.js --sign "<identity>" --validate
```

`test-native.js` führt die nativen Unit-Tests von `test/native` aus.
`host.js` baut die Container-App des Beispiels mit ihrer Erweiterung für
macOS, registriert sie und startet den Test-Host
`test/host/aud_auv3_host.swift`, der die Unit wie Logic Pro außerhalb des
eigenen Prozesses lädt: Presets, Rendering, Zustand, zwei Instanzen,
Echtzeit-Blöcke, der MIDI-Ausgang und der Editor; `--validate` startet
zusätzlich `auval`, `--play <Sekunden>` spielt live im Echtzeit-Modus.

Auf iOS: `node scripts/build-plugin.js --config example/plugin/plugin.json
--platform ios`, dann `example/ios` mit Xcode bauen und installieren; ihre
App-ID braucht die Fähigkeit Inter-App Audio.

Flutter (BSD-3-Clause) reist in der Erweiterung mit; `flutter build`
schreibt seine Hinweise und die jedes Dart-Pakets in
`App.framework/flutter_assets/NOTICES.Z`.
