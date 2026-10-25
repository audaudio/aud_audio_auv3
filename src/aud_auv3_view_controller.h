// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The principal class of the AUv3 extension (ticket 41): the factory of
// AudAuv3AudioUnit and the view a host shows as the unit's editor. An
// app's extension target names it as NSExtensionPrincipalClass.

#import <CoreAudioKit/CoreAudioKit.h>

#import "aud_auv3_audio_unit.h"

NS_ASSUME_NONNULL_BEGIN

// #############################################################################
@interface AudAuv3ViewController : AUViewController <AUAudioUnitFactory>

// .............................................................................
// The unit this view belongs to, once the host created it.
@property(nonatomic, readonly, nullable) AudAuv3AudioUnit* audioUnit;

@end

NS_ASSUME_NONNULL_END
