// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';

// #############################################################################
/// The Audio Unit of the spike S0-plugin-ui (ticket 24): its component
/// description, the channels between the extension, its Flutter editor and
/// the container app, and its read-only measurement parameters.
abstract final class AudAuv3Component {
  /// The component type: a music device (`aumu`), as the graph renders a
  /// generator.
  static const String type = 'aumu';

  /// The component subtype.
  static const String subtype = 'AudS';

  /// The manufacturer code.
  static const String manufacturer = 'Audn';

  /// The name hosts list.
  static const String name = 'Audanika: Aud Spike';

  /// The Dart entrypoint of the editor inside the extension.
  static const String editorEntrypoint = 'auEditorMain';

  /// The method channel between the extension and its editor.
  static const String editorChannel = 'aud_auv3/editor';

  /// The method channel between the container app and its native host.
  static const String hostChannel = 'aud_auv3/host';

  /// The read-only parameter with the extension's phys_footprint in MB.
  static final int footprintParam = audParamId('spike', 'footprint');

  /// The read-only parameter with the milliseconds from the editor's
  /// viewDidLoad to its first Flutter frame.
  static final int firstFrameParam = audParamId('spike', 'firstFrame');
}

// .............................................................................
/// The stable id of a graph parameter: FNV-1a over `<node id>/<param id>`
/// with the top bit cleared, as aud_host_param_id of aud_audio_graph
/// computes it.
int audParamId(String nodeId, String paramId) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode('$nodeId/$paramId')) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}
