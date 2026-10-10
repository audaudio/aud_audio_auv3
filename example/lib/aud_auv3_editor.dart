// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_audio_auv3/aud_audio_auv3.dart';
import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// #############################################################################
/// The editor of the spike's Audio Unit, inside the extension (ticket 24):
/// the knobs of aud_audio_ui_controls bound to the unit's parameters over
/// the channel [AudAuv3Component.editorChannel], and the output meter. The
/// extension starts it as the entrypoint [AudAuv3Component.editorEntrypoint]
/// of an engine of its FlutterEngineGroup. Widgets layer only.
class AudAuv3Editor extends StatefulWidget {
  // ...........................................................................
  /// Creates the editor.
  const AudAuv3Editor({super.key});

  @override
  State<AudAuv3Editor> createState() => _AudAuv3EditorState();
}

// #############################################################################
class _AudAuv3EditorState extends State<AudAuv3Editor> {
  static const _channel = MethodChannel(AudAuv3Component.editorChannel);
  static const _knobs = [
    ('osc', 'frequency', 'Frequency'),
    ('osc', 'amplitude', 'Level'),
    ('filter', 'cutoff', 'Cutoff'),
    ('filter', 'resonance', 'Resonance'),
    ('out', 'master', 'Master'),
  ];

  final _sink = _AudUnitSink(_channel);
  final _meter = ValueNotifier<double>(0);
  List<AudParamBinding> _bindings = [];

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handle);
    unawaited(_channel.invokeMethod('ready'));
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments as Map;
    switch (call.method) {
      case 'welcome':
        final params = [
          for (final p in args['params'] as List)
            Map<String, Object?>.from(p as Map),
        ];
        setState(
          () => _bindings = [
            for (final (nodeId, paramId, label) in _knobs)
              for (final p in params)
                if (p['nodeId'] == nodeId && p['paramId'] == paramId)
                  AudParamBinding(
                    sink: _sink
                      ..register(
                        AudParamAddress(nodeId, paramId),
                        p['id']! as int,
                      ),
                    spec: AudParamSpec(
                      address: AudParamAddress(nodeId, paramId),
                      min: (p['min']! as num).toDouble(),
                      max: (p['max']! as num).toDouble(),
                      defaultValue: (p['default']! as num).toDouble(),
                      logarithmic: p['logarithmic'] == true,
                      name: label,
                      unit: p['unit']! as String,
                    ),
                    initial: (p['value']! as num).toDouble(),
                  ),
          ],
        );
      case 'param':
        _sink.receive(
          (args['id']! as num).toInt(),
          (args['value']! as num).toDouble(),
        );
      case 'meter':
        _meter.value = (args['peak']! as num).toDouble();
    }
    return null;
  }

  @override
  void dispose() {
    for (final binding in _bindings) {
      binding.dispose();
    }
    _meter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFF1C1F24),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final binding in _bindings)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: AudParamKnob(binding: binding),
              ),
            SizedBox(
              width: 20,
              height: 140,
              child: ValueListenableBuilder<double>(
                valueListenable: _meter,
                builder: (context, peak, _) =>
                    CustomPaint(painter: _Meter(peak)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// The unit's parameters by address: edits and gestures as method calls,
// values from the unit as changes.
// #############################################################################
class _AudUnitSink implements AudParamSink {
  _AudUnitSink(this._channel);

  final MethodChannel _channel;
  final Map<AudParamAddress, int> _ids = {};
  final Map<int, AudParamAddress> _addresses = {};
  final _changes = StreamController<AudParamChange>.broadcast(sync: true);

  void register(AudParamAddress address, int id) {
    _ids[address] = id;
    _addresses[id] = address;
  }

  void receive(int id, double value) {
    final address = _addresses[id];
    if (address != null) _changes.add(AudParamChange(address, value));
  }

  @override
  Stream<AudParamChange> get changes => _changes.stream;

  @override
  void beginGesture(AudParamAddress address) => _gesture(address, 'begin');

  @override
  void endGesture(AudParamAddress address) => _gesture(address, 'end');

  @override
  void setValue(AudParamAddress address, double value) {
    final id = _ids[address];
    if (id == null) return;
    unawaited(_channel.invokeMethod('set', {'id': id, 'value': value}));
  }

  void _gesture(AudParamAddress address, String phase) {
    final id = _ids[address];
    if (id == null) return;
    unawaited(_channel.invokeMethod('gesture', {'id': id, 'phase': phase}));
  }
}

// #############################################################################
class _Meter extends CustomPainter {
  const _Meter(this.level);

  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final l = level.clamp(0.0, 1.0);
    canvas
      ..drawRect(Offset.zero & size, Paint()..color = const Color(0xFF33383F))
      ..drawRect(
        Rect.fromLTWH(0, size.height * (1 - l), size.width, size.height * l),
        Paint()..color = const Color(0xFF59D973),
      );
  }

  @override
  bool shouldRepaint(_Meter oldDelegate) => oldDelegate.level != level;
}
