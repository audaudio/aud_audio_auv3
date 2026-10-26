// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The editor runs Flutter inside the extension (plugin-012): the app's own
// Dart code - on macOS from the Dart bundle the extension carries in its
// Frameworks (the App Sandbox lets it read its own bundle, not the app
// around it), on iOS from the app's Frameworks, as Flutter itself (an iOS
// extension may carry no frameworks of its own) -, started at the entry point the extension's Info.plist names as
// AudAuv3EditorEntrypoint when the view first appears, with the argument
// `--aud-auv3-instance=<n>` of its bridge. On iOS the engines of all
// instances come from one FlutterEngineGroup per process; on macOS each
// view has its engine, which runs once its view controller exists. The
// editor talks to the unit with dart:ffi (aud_auv3_editor_api.h). Without
// an entry point the view stays empty.

#import "aud_auv3_view_controller.h"

#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

#import "aud_auv3_editor_bridge.h"

#include "aud_auv3_shared.hpp"

using namespace aud_auv3;

namespace {

// The editor's entry point, or nil for none.
NSString* editorEntrypoint() {
  id value = [NSBundle mainBundle].infoDictionary[@"AudAuv3EditorEntrypoint"];
  return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

// The Dart bundle: inside the extension on macOS, in the app around it on
// iOS (<app>/PlugIns/<extension>.appex).
NSBundle* dartBundle() {
#if TARGET_OS_OSX
  NSString* path = @"Contents/Frameworks/App.framework";
#else
  NSString* path = @"../../Frameworks/App.framework";
#endif
  NSURL* url = [[NSBundle mainBundle].bundleURL URLByAppendingPathComponent:path];
  return [NSBundle bundleWithURL:url.URLByStandardizingPath];
}

NSArray<NSString*>* editorArguments(AudAuv3EditorBridge* bridge) {
  return @[ [NSString stringWithFormat:@"--aud-auv3-instance=%lld", bridge.instance] ];
}

}  // namespace

@implementation AudAuv3ViewController {
  AudAuv3AudioUnit* _audioUnit;
  FlutterEngine* _engine;
  FlutterViewController* _flutter;
  AudAuv3EditorBridge* _bridge;
  BOOL _visible;
}

#if !TARGET_OS_OSX
+ (FlutterEngineGroup*)engineGroup {
  static FlutterEngineGroup* group;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    FlutterDartProject* project = [[FlutterDartProject alloc] initWithPrecompiledDartBundle:dartBundle()];
    group = [[FlutterEngineGroup alloc] initWithName:@"aud_auv3" project:project];
  });
  return group;
}
#endif

- (AUAudioUnit*)createAudioUnitWithComponentDescription:(AudioComponentDescription)description
                                                  error:(NSError**)error {
  AudAuv3AudioUnit* unit = [[AudAuv3AudioUnit alloc] initWithComponentDescription:description
                                                                          options:0
                                                                            error:error];
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_audioUnit = unit;
    [self startEditor];
  });
  return unit;
}

- (AudAuv3AudioUnit*)audioUnit {
  return _audioUnit;
}

#if TARGET_OS_OSX
- (void)loadView {
  self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 640)];
  self.preferredContentSize = NSMakeSize(1024, 640);
}

- (void)viewWillAppear {
  [super viewWillAppear];
  _visible = YES;
  [self startEditor];
}

- (void)viewDidDisappear {
  [super viewDidDisappear];
  _visible = NO;
  [self stopEditor];
}
#else
- (void)viewDidLoad {
  [super viewDidLoad];
  self.preferredContentSize = CGSizeMake(1024, 640);
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  _visible = YES;
  [self startEditor];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  _visible = NO;
  [self stopEditor];
}
#endif

// Starts the editor once the view shows and the unit exists; a unit
// without an open editor carries none of Flutter.
- (void)startEditor {
  if (_engine != nil || _audioUnit == nil || !_visible) return;
  NSString* entrypoint = editorEntrypoint();
  if (entrypoint == nil) return;
  _bridge = [[AudAuv3EditorBridge alloc] initWithUnit:_audioUnit];
#if TARGET_OS_OSX
  FlutterDartProject* project = [[FlutterDartProject alloc] initWithPrecompiledDartBundle:dartBundle()];
  project.dartEntrypointArguments = editorArguments(_bridge);
  _engine = [[FlutterEngine alloc] initWithName:@"aud_auv3" project:project allowHeadlessExecution:NO];
  // On macOS an engine runs only once its view controller exists.
  _flutter = [[FlutterViewController alloc] initWithEngine:_engine nibName:nil bundle:nil];
  if (![_engine runWithEntrypoint:entrypoint]) {
    logError("The editor does not start");
    [self stopEditor];
    return;
  }
  _flutter.view.frame = self.view.bounds;
  _flutter.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addChildViewController:_flutter];
  [self.view addSubview:_flutter.view];
#else
  FlutterEngineGroupOptions* options = [[FlutterEngineGroupOptions alloc] init];
  options.entrypoint = entrypoint;
  options.entrypointArgs = editorArguments(_bridge);
  _engine = [[AudAuv3ViewController engineGroup] makeEngineWithOptions:options];
  _flutter = [[FlutterViewController alloc] initWithEngine:_engine nibName:nil bundle:nil];
  [self addChildViewController:_flutter];
  _flutter.view.frame = self.view.bounds;
  _flutter.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:_flutter.view];
  [_flutter didMoveToParentViewController:self];
#endif
  logInfo("The editor of instance " + std::to_string(_bridge.instance) + " starts");
}

// The view went away: the editor's notes end and Flutter stops with it.
- (void)stopEditor {
  [_bridge end];
  _bridge = nil;
  if (_flutter != nil) {
#if TARGET_OS_OSX
    [_flutter.view removeFromSuperview];
    [_flutter removeFromParentViewController];
#else
    [_flutter willMoveToParentViewController:nil];
    [_flutter.view removeFromSuperview];
    [_flutter removeFromParentViewController];
#endif
  }
#if TARGET_OS_OSX
  [_engine shutDownEngine];
#else
  [_engine destroyContext];
#endif
  _flutter = nil;
  _engine = nil;
}

@end
