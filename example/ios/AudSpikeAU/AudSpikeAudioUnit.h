// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#import <AudioToolbox/AudioToolbox.h>

#include "aud_auv3_engine.h"

NS_ASSUME_NONNULL_BEGIN

// The Audio Unit of the spike S0-plugin-ui (ticket 24): the graph of the
// VST3 spike over the headless host (src/aud_auv3_engine.h), its parameters
// under their stable ids, and two read-only parameters that report the
// extension process's phys_footprint and the editor's first frame to the
// host. The first unit of a process touches a 100 MB ballast in place of
// the sampler (decision 4 of the plan review of ticket 23).
@interface AudSpikeAudioUnit : AUAudioUnit

// The id of the parameter with the footprint in MB.
@property(class, nonatomic, readonly) AUParameterAddress footprintAddress;

// The id of the parameter with the first frame in milliseconds.
@property(class, nonatomic, readonly) AUParameterAddress firstFrameAddress;

// The engine, for the editor's meter.
@property(nonatomic, readonly, nullable) AudAuv3Engine* engine;

// Reports the editor's first frame.
- (void)reportFirstFrame:(double)milliseconds;

@end

NS_ASSUME_NONNULL_END
