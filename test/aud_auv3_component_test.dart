// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_auv3/aud_audio_auv3.dart';
import 'package:test/test.dart';

void main() {
  group('audParamId(nodeId, paramId)', () {
    test('is FNV-1a of "<node id>/<param id>" with the top bit cleared', () {
      // FNV-1a of "osc/frequency" is 0xb697a565: its id has the top bit
      // cleared.
      expect([
        audParamId('a', 'b'),
        audParamId('osc', 'frequency'),
      ], equals([0x3a8e75c1, 0x3697a565]));
    });
  });

  group('AudAuv3Component', () {
    test('names the unit and its channels', () {
      expect(
        [
          AudAuv3Component.type,
          AudAuv3Component.subtype,
          AudAuv3Component.manufacturer,
          AudAuv3Component.name,
          AudAuv3Component.editorEntrypoint,
          AudAuv3Component.editorChannel,
          AudAuv3Component.hostChannel,
        ],
        equals([
          'aumu',
          'AudS',
          'Audn',
          'Audanika: Aud Spike',
          'auEditorMain',
          'aud_auv3/editor',
          'aud_auv3/host',
        ]),
      );
    });

    test('gives its measurement parameters the ids of node spike', () {
      expect(
        [AudAuv3Component.footprintParam, AudAuv3Component.firstFrameParam],
        equals([
          audParamId('spike', 'footprint'),
          audParamId('spike', 'firstFrame'),
        ]),
      );
    });
  });
}
