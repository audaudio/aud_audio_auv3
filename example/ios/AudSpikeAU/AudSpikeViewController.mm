// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#import "AudSpikeViewController.h"

#import <Flutter/Flutter.h>
#import <QuartzCore/QuartzCore.h>

#import "AudSpikeAudioUnit.h"

#include "aud_auv3_engine.h"

namespace {

// AUD_PARAM_LOGARITHMIC of aud_audio_core.
constexpr uint32_t kParamLogarithmic = 1u << 3;

}  // namespace

@implementation AudSpikeViewController {
  AudSpikeAudioUnit* _audioUnit;
  FlutterEngine* _engine;
  FlutterViewController* _flutter;
  FlutterMethodChannel* _channel;
  AUParameterObserverToken _token;
  NSTimer* _meterTimer;
  CFTimeInterval _loadStart;
  BOOL _ready;
  BOOL _welcomed;
  // The values the editor shows, and the parameters it is dragging: host
  // automation reaches only the engine, so the meter timer sends the
  // values that changed, except those of a running gesture.
  NSMutableDictionary<NSNumber*, NSNumber*>* _shown;
  NSMutableSet<NSNumber*>* _dragging;
}

+ (FlutterEngineGroup*)engineGroup {
  static FlutterEngineGroup* group;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    group = [[FlutterEngineGroup alloc] initWithName:@"aud_auv3" project:nil];
  });
  return group;
}

- (AUAudioUnit*)createAudioUnitWithComponentDescription:(AudioComponentDescription)description
                                                  error:(NSError**)error {
  AudSpikeAudioUnit* unit = [[AudSpikeAudioUnit alloc] initWithComponentDescription:description
                                                                              error:error];
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_audioUnit = unit;
    [self welcomeIfReady];
  });
  return unit;
}

// The extension loads this view when the system creates the unit, before
// a host asks for an editor; Flutter starts only when the view appears, so
// that a unit without an open editor carries none of it.
- (void)viewDidLoad {
  [super viewDidLoad];
  self.preferredContentSize = CGSizeMake(620, 220);
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self startFlutter];
}

- (void)startFlutter {
  if (_engine != nil) return;
  _loadStart = CACurrentMediaTime();
  FlutterEngineGroupOptions* options = [[FlutterEngineGroupOptions alloc] init];
  options.entrypoint = @"auEditorMain";
  _engine = [[AudSpikeViewController engineGroup] makeEngineWithOptions:options];
  _flutter = [[FlutterViewController alloc] initWithEngine:_engine nibName:nil bundle:nil];
  [self addChildViewController:_flutter];
  _flutter.view.frame = self.view.bounds;
  _flutter.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:_flutter.view];
  [_flutter didMoveToParentViewController:self];
  __weak AudSpikeViewController* weakSelf = self;
  [_flutter setFlutterViewDidRenderCallback:^{
    [weakSelf firstFrame];
  }];
  _channel = [FlutterMethodChannel methodChannelWithName:@"aud_auv3/editor"
                                         binaryMessenger:_engine.binaryMessenger];
  [_channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [weakSelf handle:call];
    result(nil);
  }];
}

- (void)dealloc {
  [_meterTimer invalidate];
  if (_token != nil && _audioUnit != nil) {
    [_audioUnit.parameterTree removeParameterObserver:_token];
  }
}

- (void)firstFrame {
  const double milliseconds = (CACurrentMediaTime() - _loadStart) * 1000;
  NSLog(@"aud_auv3 first frame %.1f ms", milliseconds);
  [_audioUnit reportFirstFrame:milliseconds];
}

- (void)handle:(FlutterMethodCall*)call {
  NSDictionary* args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;
  if ([call.method isEqualToString:@"ready"]) {
    _ready = YES;
    [self welcomeIfReady];
    return;
  }
  AUParameter* parameter =
      [_audioUnit.parameterTree parameterWithAddress:[args[@"id"] unsignedLongLongValue]];
  if (parameter == nil) return;
  if ([call.method isEqualToString:@"set"]) {
    _shown[@(parameter.address)] = @([args[@"value"] floatValue]);
    [parameter setValue:[args[@"value"] floatValue]
             originator:_token
             atHostTime:0
              eventType:AUParameterAutomationEventTypeValue];
  } else if ([call.method isEqualToString:@"gesture"]) {
    const BOOL begin = [args[@"phase"] isEqualToString:@"begin"];
    if (begin) {
      [_dragging addObject:@(parameter.address)];
    } else {
      [_dragging removeObject:@(parameter.address)];
    }
    [parameter setValue:parameter.value
             originator:_token
             atHostTime:0
              eventType:begin ? AUParameterAutomationEventTypeTouch
                              : AUParameterAutomationEventTypeRelease];
  }
}

// Sends the parameters once the unit exists and the editor listens.
- (void)welcomeIfReady {
  if (!_ready || _audioUnit == nil || _welcomed) return;
  _welcomed = YES;
  _shown = [NSMutableDictionary dictionary];
  _dragging = [NSMutableSet set];
  // The parameters as the engine describes them; only the values come from
  // the parameter tree.
  AudAuv3Engine* engine = _audioUnit.engine;
  NSMutableArray* params = [NSMutableArray array];
  const uint32_t count = aud_auv3_engine_num_params(engine);
  for (uint32_t i = 0; i < count; ++i) {
    AudAuv3Param p{};
    if (aud_auv3_engine_param(engine, i, &p) != 0) continue;
    AUParameter* parameter = [_audioUnit.parameterTree parameterWithAddress:p.id];
    const AUValue value =
        parameter != nil ? parameter.value : aud_auv3_engine_get_param(engine, p.id);
    _shown[@(p.id)] = @(value);
    [params addObject:@{
      @"id" : @(p.id),
      @"nodeId" : @(p.nodeId),
      @"paramId" : @(p.paramId),
      @"node" : @0,
      @"index" : @(i),
      @"name" : @(p.name),
      @"unit" : @(p.unit),
      @"min" : @(p.min),
      @"max" : @(p.max),
      @"default" : @(p.defaultValue),
      @"value" : @(value),
      @"logarithmic" : @((p.flags & kParamLogarithmic) != 0),
      @"steps" : @(p.steps),
    }];
  }
  [_channel invokeMethod:@"welcome" arguments:@{@"params" : params}];
  __weak AudSpikeViewController* weakSelf = self;
  FlutterMethodChannel* channel = _channel;
  _token = [_audioUnit.parameterTree
      tokenByAddingParameterObserver:^(AUParameterAddress address, AUValue value) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [channel invokeMethod:@"param" arguments:@{@"id" : @(address), @"value" : @(value)}];
        });
      }];
  _meterTimer = [NSTimer timerWithTimeInterval:1.0 / 30
                                       repeats:YES
                                         block:^(NSTimer* timer) {
                                           [weakSelf sendMeter];
                                         }];
  [[NSRunLoop mainRunLoop] addTimer:_meterTimer forMode:NSRunLoopCommonModes];
}

- (void)sendMeter {
  AudAuv3Engine* engine = _audioUnit.engine;
  float peak = 0;
  float rms = 0;
  aud_auv3_engine_meter(engine, &peak, &rms);
  [_channel invokeMethod:@"meter" arguments:@{@"peak" : @(peak), @"rms" : @(rms)}];
  // Host automation: the values the engine plays now.
  for (NSNumber* address in _shown.allKeys) {
    if ([_dragging containsObject:address]) continue;
    const float value = aud_auv3_engine_get_param(engine, address.unsignedIntValue);
    if (value == _shown[address].floatValue) continue;
    _shown[address] = @(value);
    [_channel invokeMethod:@"param" arguments:@{@"id" : address, @"value" : @(value)}];
  }
}

@end
