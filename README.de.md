# aud_audio_auv3

Audio Unit v3 extension of the Audanika Audio Engine over its headless host.

Teil der Audanika Audio Engine; geplant in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Was das Paket enthält (0.1.0, Ticket 24)

Der iOS-Teil des Spikes S0-plugin-ui: eine AUv3-Extension mit einem
Flutter-Editor. Die Entscheidung plugin-003 stützt sich auf seine
Messungen; die Shell selbst ist Schritt S20.

- Die Engine (`src/aud_auv3_engine.h`): eine C-API über dem Headless Host
  von `aud_audio_graph`, die das Graph-Dokument des Spikes rendert, mit
  stabilen Parameter-Ids und einem Pegel. `scripts/build-engine.js` baut
  sie als statische Bibliothek für `iphoneos` und `iphonesimulator` nach
  `build/ios`.
- `AudAuv3Component` (`lib/`): die Komponentenbeschreibung, die
  Kanalnamen und die Parameter-Ids, die die Extension, ihr Editor und die
  Container-App teilen.
- Das Beispiel (`example/`): die Container-App und die Extension
  `AudSpikeAU`.
  - Die Extension: eine `AUAudioUnit` mit Parameterbaum und Render-Block
    über der Engine und einem Ballast von 100 MB, der für den Sampler
    steht. Ihr `AUViewController` zeigt einen Flutter-Editor, dessen
    Engines aus einer `FlutterEngineGroup` stammen und starten, wenn die
    View zum ersten Mal erscheint; die Knöpfe schreiben in den
    Parameterbaum.
  - Die App lädt eine bis vier Instanzen außerhalb ihres Prozesses, öffnet
    ihre Editoren und meldet einmal pro Sekunde den `phys_footprint` der
    Extension und die ersten Frames der Editoren, auf dem Bildschirm und
    auf stderr.

## Bauen und starten

```bash
node scripts/build-engine.js
cd example
flutter build ios --release
xcrun devicectl device install app --device <id> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <id> --console \
  com.audanika.audAudioAuv3 -- --instances 2 --duration 600
```

Die App-ID der App braucht die Capability Inter-App Audio: ohne sie
verweigert iOS das Laden der Extension außerhalb des Prozesses
(`kAudioComponentErr_NotPermitted`).

Flutter (BSD-3-Clause) reist in der Extension mit; `flutter build`
schreibt seine Hinweise und die jedes Dart-Pakets nach
`App.framework/flutter_assets/NOTICES.Z`.
