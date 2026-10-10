// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The Audio Unit v3 shell of the Audanika Audio Engine. The extension
/// itself is Objective-C++ over the headless host (`src/`, the example's
/// iOS project); this library holds what the container app and the
/// extension's Flutter editor share (ticket 24).
library;

export 'src/aud_audio_auv3_version.dart';
export 'src/aud_auv3_component.dart';
