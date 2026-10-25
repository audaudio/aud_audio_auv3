// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The Audio Unit v3 shell of the Audanika Audio Engine. The extension
/// itself is Objective-C++ (`src/`, built by `scripts/build-plugin.js`);
/// this library is the end of the shell protocol for an editor that runs
/// inside the extension: [AudAuv3Shell], over `dart:ffi` (ticket 41). The
/// messages come from aud_audio_plugin and are exported here as well.
library;

export 'package:aud_audio_plugin/aud_audio_plugin.dart';

export 'src/aud_audio_auv3_version.dart';
export 'src/aud_auv3_shell.dart';
