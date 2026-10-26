// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The unit's end of the shell protocol for an editor inside the extension
// (ticket 64, plugin-012): the messages of aud_audio_plugin's
// AudShellMessage as JSON, carried in process through the C interface of
// aud_auv3_editor_api.h, which the editor's Dart code calls with dart:ffi.
// Each bridge has an instance number, which the view controller hands the
// editor as its start argument and the editor connects with.
//
// - hello: answered with the welcome - the document's name and parameters,
//   the presets, the preset that plays and the editor's settings
// - selectPreset: chooses the preset, as the host's preset menu does
// - midi: plays the editor's MIDI 1.0 messages at the next block's start
//   and keeps track of the notes the editor holds, which end() releases
// - settings: kept with the host's project (fullState)
// - preset: sent to the editor whenever the playing preset changes, chosen
//   by the editor, the host, its automation or a restored project
//
// Main thread only.

#import <Foundation/Foundation.h>

#import "aud_auv3_audio_unit.h"

NS_ASSUME_NONNULL_BEGIN

// #############################################################################
@interface AudAuv3EditorBridge : NSObject

// .............................................................................
// A bridge between `unit` and its editor, registered under a new instance
// number until it ends.
- (instancetype)initWithUnit:(AudAuv3AudioUnit*)unit;

// .............................................................................
// The number the editor connects with (aud_auv3_editor_connect).
@property(nonatomic, readonly) int64_t instance;

// .............................................................................
// Takes a message of the editor.
- (void)receive:(NSDictionary<NSString*, id>*)message;

// .............................................................................
// The editor went away: the notes it holds end, the bridge stops sending.
- (void)end;

// .............................................................................
// When the editor said hello, in seconds since the bridge started; 0 before.
@property(nonatomic, readonly) NSTimeInterval helloAfter;

@end

NS_ASSUME_NONNULL_END
