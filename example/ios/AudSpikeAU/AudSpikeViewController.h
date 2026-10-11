// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#import <CoreAudioKit/CoreAudioKit.h>

NS_ASSUME_NONNULL_BEGIN

// The principal class of the Audio Unit extension (ticket 24): creates the
// unit and shows the Flutter editor of the spike - a FlutterViewController
// whose engine comes from one FlutterEngineGroup per extension process, so
// the editors of several instances share the Dart VM and the isolate group.
@interface AudSpikeViewController : AUViewController <AUAudioUnitFactory>
@end

NS_ASSUME_NONNULL_END
