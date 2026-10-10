// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_auv3/aud_audio_auv3.dart';
import 'package:test/test.dart';

void main() {
  group('audParamId', () {
    test('is FNV-1a with the top bit cleared', () {
      // FNV-1a of "a/b" is 0x0cc8b52c... computed by the reference below.
      int reference(String text) {
        var hash = 0x811c9dc5;
        for (final unit in text.codeUnits) {
          hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
        }
        return hash & 0x7FFFFFFF;
      }

      expect(audParamId('osc', 'frequency'), reference('osc/frequency'));
      expect(audParamId('spike', 'test'), reference('spike/test'));
      expect(audParamId('a', 'b') & 0x80000000, 0);
    });
  });

  group('AudAuv3Component', () {
    test('names the unit and its channels', () {
      expect(AudAuv3Component.type, 'aumu');
      expect(AudAuv3Component.subtype, 'AudS');
      expect(AudAuv3Component.manufacturer, 'Audn');
      expect(AudAuv3Component.name, 'Audanika: Aud Spike');
      expect(AudAuv3Component.editorEntrypoint, 'auEditorMain');
      expect(AudAuv3Component.editorChannel, 'aud_auv3/editor');
      expect(AudAuv3Component.hostChannel, 'aud_auv3/host');
      expect(AudAuv3Component.footprintParam, audParamId('spike', 'footprint'));
      expect(
        AudAuv3Component.firstFrameParam,
        audParamId('spike', 'firstFrame'),
      );
      expect(
        AudAuv3Component.footprintParam,
        isNot(AudAuv3Component.firstFrameParam),
      );
    });
  });
}
