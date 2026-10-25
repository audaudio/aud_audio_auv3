// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The Audio Unit of the AUv3 shell (ticket 41, plugin-011): the engine of
// aud_audio_plugin with the graph document, presets and node packages an
// app configures in the extension's aud_plugin folder (plugin.json,
// document.json, presets.json), its content found through plugin.json
// `content` around the extension's bundle.
//
// - Parameters: "Preset" (indexed, the stable id of the shell's preset
//   parameter, identifier `preset`), the graph parameters plugin.json
//   lists with their plain ranges (`<node>_<param>`), and the controls
//   (`control_<id>`), which send their control change only once they
//   move. An identifier holds no '.', the tree's delimiter.
// - Presets: the factory presets, in the order of presets.json;
//   currentPreset and "Preset" follow each other.
// - State: fullState carries the shell's state (encodeState) under
//   `aud_state` - the preset id, the parameter values, the moved controls
//   and the editor's settings, never a path.
// - Render: the host's MIDI 1.0 messages, UMP event lists and scheduled
//   parameter changes at their sample offsets, the notes of the editor at
//   the block's start, the host's musical context and transport state as
//   the graph's transport; offline, a block waits for its preset to load.
//
// The extension's principal class (AudAuv3ViewController) creates it.

#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

// #############################################################################
@interface AudAuv3AudioUnit : AUAudioUnit

// .............................................................................
// [main] Plays a MIDI 1.0 channel voice message of the editor at the start
// of the next block.
- (void)playEditorStatus:(uint8_t)status data1:(uint8_t)data1 data2:(uint8_t)data2;

// .............................................................................
// [main] The settings of the editor as the editor wrote them; kept with the
// host's project in fullState. A change notifies the observers of fullState
// and fullStateForDocument; settings longer than kMaxEditorSettings bytes
// are refused.
@property(nonatomic, copy) NSString* editorSettings;

// .............................................................................
// The names of the presets, in the order of the factory presets.
@property(nonatomic, readonly) NSArray<NSString*>* presetNames;

// .............................................................................
// The index of the preset that plays; KVO-observable on the main thread.
@property(nonatomic, readonly) NSInteger presetIndex;

// .............................................................................
// [main] Chooses the preset at `index`, as the host's preset menu does.
- (void)selectPreset:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
