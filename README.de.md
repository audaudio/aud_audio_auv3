# aud_audio_auv3

[English](README.md) | Deutsch

Audio-Unit-v3-Erweiterung der Audanika Audio Engine über ihrem
Headless-Host.

Die AUv3-Hülle (Ticket 64, Schritt S20) auf macOS und iOS: Eine App
konfiguriert sie mit einer `plugin.json`, einem Graph-Dokument und dessen
Presets und erhält eine Audio-Unit-Erweiterung mit dem Klang der App und
der eigenen Flutter-Oberfläche der App als Editor. Teil der Audanika Audio
Engine; geplant in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Motivation

Eine App, die ihren Klang über die Engine spielt, will diesen Klang auch
in einem Audio-Unit-Host wie Logic Pro, GarageBand oder Loopy Pro, ohne
die Erweiterung selbst zu schreiben. Dieses Paket ist das AUv3-Format der
Engine: Der formatneutrale Kern - die Engine über dem Headless-Host, die
Konfiguration, Presets, Zustand, MIDI-Events, Transport und das
Shell-Protokoll - kommt aus `aud_audio_plugin`; dieses Paket ergänzt die
`AUAudioUnit`, den Editor innerhalb der Erweiterung und den Build der
statischen Bibliothek, die das Erweiterungs-Target einer App linkt.

## Installation

Das Paket ist nicht auf pub.dev veröffentlicht; es kommt als
Git-Abhängigkeit dazu:

```yaml
dependencies:
  aud_audio_auv3:
    git:
      url: git@github.com:audaudio/aud_audio_auv3.git
      tag_pattern: "{{version}}"
    version: ^0.2.1
```

## Verwendung

Der Editor läuft innerhalb der Erweiterung: Der View-Controller startet
ihn an einem Dart-Einstiegspunkt mit der Instanz seiner Unit, und der
Editor spricht über `AudAuv3Shell` mit `dart:ffi` mit der Unit, im
Shell-Protokoll von `aud_audio_plugin`. Aus `example/lib/main.dart`:

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

Das Beispiel (`example/`) ist die Unit „Aud Example" aus den eigenen
Knoten des Graphen, ihre Container-App für macOS und iOS und ein Editor
mit ihren Presets und vier Tasten. Die Unit wird aus der `plugin.json` des
Beispiels gebaut, danach die Container-App mit Xcode gebaut und
installiert:

```bash
node scripts/build-plugin.js --config example/plugin/plugin.json --platform ios
```

Das Projekt nennt kein Team, also `example/ios` unter dem eigenen bauen,
z. B. `xcodebuild … DEVELOPMENT_TEAM=<team>`; ihre App-ID braucht die
Fähigkeit Inter-App Audio. Die Unit spielt dann in einem Audio-Unit-Host.

## Grenzen

- macOS (arm64) und iOS, der Simulator eingeschlossen; keine andere
  Plattform
- Das Erweiterungs-Target enthält keinen eigenen Code: Unit, Editor und
  Build kommen aus diesem Paket, Klang und Oberfläche aus der App
- Flutter (BSD-3-Clause) reist in der Erweiterung mit; `flutter build`
  schreibt seine Hinweise und die jedes Dart-Pakets in
  `App.framework/flutter_assets/NOTICES.Z`

## Dokumentation

- [doc/plugin-bundle.md](doc/plugin-bundle.md): was eine App dem Paket
  übergibt, um eine eigene Audio Unit zu bauen - die `plugin.json`, das
  Graph-Dokument, die Presets und das Erweiterungs-Target
- Die Guides in [doc/guides](doc/guides) und die Blogbeiträge in
  [doc/de/blog](doc/de/blog)
- Die Änderungen je Version in [CHANGELOG.md](CHANGELOG.md)

## Funktionsweise

- Die Unit (`src/aud_auv3_audio_unit.h`): eine `AUAudioUnit` über der
  Engine von `aud_audio_plugin` - Parameter, Werks-Presets, `fullState`
  mit den Einstellungen des Editors, deren Änderung den Host benachrichtigt,
  MIDI und Transport des Hosts, Offline-Rendering, die Noten des Editors
  als MIDI-Ausgang „MIDI Out" und eine Render-Messung alle 2 s im
  Systemprotokoll.
- Der Editor (`src/aud_auv3_view_controller.mm`,
  `src/aud_auv3_editor_bridge.h`): Flutter innerhalb der Erweiterung, das
  mit `dart:ffi` (`src/aud_auv3_editor_api.h`) im Shell-Protokoll von
  `aud_audio_plugin` mit der Unit spricht.
- Der Build (`scripts/build-plugin.js`): eine statische Bibliothek je
  Plattform (macOS arm64, iOS, der Simulator), die `Info.plist` der
  Erweiterung und eine xcconfig für das Erweiterungs-Target einer App, das
  keinen eigenen Code enthält.
- Dart (`lib/`): `AudAuv3Shell`, das Ende des Protokolls im Editor.

## Status

Vor 1.0 - die API kann sich zwischen Minor-Versionen ändern.

## Mitwirken

Tickets laufen über den `gg`-Workflow: siehe den
[Develop Guide](doc/guides/develop-guide.md) und den
[Review Guide](doc/guides/for-ai/ai-review-guide.md). Bauen und testen:

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
zusätzlich `auval`, `--play <seconds>` spielt live im Echtzeit-Modus.

## Lizenz

MIT - siehe [LICENSE](LICENSE).
