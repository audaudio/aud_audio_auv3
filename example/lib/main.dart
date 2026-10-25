// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_audio_auv3/aud_audio_auv3.dart';
import 'package:flutter/widgets.dart';

// #############################################################################
/// The container app of the example AUv3 (ticket 41): the app only carries
/// the extension, which the system registers with it; the unit plays in a
/// host such as Logic Pro, GarageBand or Loopy Pro.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const _Page(
      child: Text(
        'aud_audio_auv3 example\n\n'
        'This app carries the AUv3 "Aud Example". Open it in an Audio Unit '
        'host, e.g. Logic Pro, GarageBand or Loopy Pro.',
      ),
    ),
  );
}

// #############################################################################
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

// #############################################################################
class _Page extends StatelessWidget {
  const _Page({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFF14325A),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 16, color: Color(0xFFFFFFFF)),
          child: child,
        ),
      ),
    ),
  );
}

// #############################################################################
/// The presets of the unit to choose from and four keys that play C, E, G
/// and C on MIDI channel 1.
class _Editor extends StatefulWidget {
  const _Editor({required this.shell});

  final AudAuv3Shell shell;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  List<AudShellPresetInfo> _presets = const [];
  int _preset = -1;

  @override
  void initState() {
    super.initState();
    widget.shell.messages.listen(_receive);
    widget.shell.send(AudShellHello(token: '', instance: 0, pid: pid));
  }

  @override
  void dispose() {
    widget.shell.close();
    super.dispose();
  }

  void _receive(AudShellMessage message) {
    switch (message) {
      case AudShellWelcome():
        setState(() {
          _presets = message.presets;
          _preset = message.preset;
        });
      case AudShellPreset():
        setState(() => _preset = message.index);
      default:
        break;
    }
  }

  void _key(int pitch, {required bool down}) {
    widget.shell.send(
      AudShellMidi([down ? 0x90 : 0x80, pitch, down ? 100 : 0]),
    );
  }

  @override
  Widget build(BuildContext context) => _Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Aud Example', style: TextStyle(fontSize: 22)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _presets.length; ++i)
              GestureDetector(
                onTap: () => widget.shell.send(AudShellSelectPreset(i)),
                child: _Box(label: _presets[i].name, highlighted: i == _preset),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            for (final pitch in const [60, 64, 67, 72])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Listener(
                  onPointerDown: (_) => _key(pitch, down: true),
                  onPointerUp: (_) => _key(pitch, down: false),
                  onPointerCancel: (_) => _key(pitch, down: false),
                  child: _Box(label: '$pitch', highlighted: false, tall: true),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

// #############################################################################
class _Box extends StatelessWidget {
  const _Box({
    required this.label,
    required this.highlighted,
    this.tall = false,
  });

  final String label;
  final bool highlighted;
  final bool tall;

  @override
  Widget build(BuildContext context) => Container(
    width: tall ? 64 : null,
    height: tall ? 120 : 44,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    alignment: Alignment.center,
    color: highlighted ? const Color(0xFFFFB000) : const Color(0xFF2E5A8C),
    child: Text(label),
  );
}
