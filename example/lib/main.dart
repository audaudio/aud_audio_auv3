// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_auv3/aud_audio_auv3.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'aud_auv3_editor.dart';

// #############################################################################
/// The container app of the spike's Audio Unit (ticket 24). Its native
/// part (ios/Runner/AppDelegate.swift) hosts one, two or four instances of
/// the unit out of process, opens their editors and reports the extension's
/// footprint; this screen shows what it reports.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _HostScreen());
}

// #############################################################################
/// The editor inside the Audio Unit extension.
@pragma('vm:entry-point')
void auEditorMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AudAuv3Editor());
}

// #############################################################################
class _HostScreen extends StatefulWidget {
  const _HostScreen();

  @override
  State<_HostScreen> createState() => _HostScreenState();
}

// #############################################################################
class _HostScreenState extends State<_HostScreen> {
  static const _channel = MethodChannel(AudAuv3Component.hostChannel);
  final List<String> _lines = [];

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'status') {
        setState(() {
          _lines.insert(0, call.arguments as String);
          if (_lines.length > 12) _lines.removeLast();
        });
      }
      return null;
    });
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFF101215),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 13, color: Color(0xFFCCCCCC)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'aud_audio_auv3 spike host',
                style: TextStyle(fontSize: 18, color: Color(0xFFFFFFFF)),
              ),
              const SizedBox(height: 12),
              for (final line in _lines) Text(line),
            ],
          ),
        ),
      ),
    ),
  );
}
