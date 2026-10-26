// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';
import 'dart:io';

import 'package:aud_audio_auv3/aud_audio_auv3.dart';
import 'package:test/test.dart';

void main() {
  group('AudAuv3Shell', () {
    late DynamicLibrary loopback;

    // The C interface without a unit (test/ffi/aud_auv3_loopback.c).
    setUpAll(() {
      final dir = Directory.systemTemp.createTempSync('aud_auv3_shell');
      final library = '${dir.path}/libaud_auv3_loopback.dylib';
      final result = Process.runSync('clang', [
        '-dynamiclib',
        '-o',
        library,
        'test/ffi/aud_auv3_loopback.c',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      loopback = DynamicLibrary.open(library);
    });

    test('instanceOf reads the start argument', () {
      expect(AudAuv3Shell.instanceOf(['--aud-auv3-instance=12']), 12);
      expect(AudAuv3Shell.instanceOf(['x', '--aud-auv3-instance=3']), 3);
      expect(AudAuv3Shell.instanceOf(['--aud-auv3-instance=x']), isNull);
      expect(AudAuv3Shell.instanceOf([]), isNull);
    });

    test('sends messages and receives the unit\'s', () async {
      final shell = AudAuv3Shell.connect(7, library: loopback);
      expect(shell.instance, 7);
      final received = shell.messages.first;
      shell.send(const AudShellSelectPreset(2));
      final message = await received;
      expect(message, isA<AudShellSelectPreset>());
      expect((message as AudShellSelectPreset).index, 2);
      shell.close();
    });

    test('ignores a reply that is no message', () async {
      final shell = AudAuv3Shell.connect(7, library: loopback);
      final received = shell.messages.toList();
      shell.send(const AudShellSelectPreset(99));
      shell.send(const AudShellSelectPreset(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      shell.close();
      final messages = await received;
      expect(messages, hasLength(1));
      expect((messages.single as AudShellSelectPreset).index, 1);
    });

    test('sends nothing after close and closes once', () async {
      final shell = AudAuv3Shell.connect(7, library: loopback);
      shell.close();
      shell.send(const AudShellSelectPreset(1));
      shell.close();
      expect(await shell.messages.isEmpty, isTrue);
    });

    test('refuses an instance the unit does not know', () {
      expect(
        () => AudAuv3Shell.connect(8, library: loopback),
        throwsStateError,
      );
    });
  }, testOn: 'mac-os');
}
