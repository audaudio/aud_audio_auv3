// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#import "AudSpikeAudioUnit.h"

#import <AVFoundation/AVFoundation.h>
#include <mach/mach.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <thread>

namespace {

constexpr AUAudioFrameCount kMaxFrames = 4096;

// The ballast of the process: 100 MB, every page touched. Pseudo-random
// words, as samples would be: a constant pattern shrinks in the memory
// compressor and no longer counts in the footprint. The volatile pointer
// keeps the compiler from dropping the allocation.
uint64_t* volatile gBallast = nullptr;

void ensureBallast() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const size_t words = (100u << 20) / sizeof(uint64_t);
    auto* ballast = static_cast<uint64_t*>(std::malloc(words * sizeof(uint64_t)));
    uint64_t x = 0x9e3779b97f4a7c15ull;
    for (size_t i = 0; i < words; ++i) {
      // xorshift64
      x ^= x << 13;
      x ^= x >> 7;
      x ^= x << 17;
      ballast[i] = x;
    }
    gBallast = ballast;
  });
}

uint32_t stableId(const char* text) {
  uint32_t hash = 0x811c9dc5u;
  for (const char* c = text; *c != 0; ++c) {
    hash ^= static_cast<uint8_t>(*c);
    hash *= 0x01000193u;
  }
  return hash & 0x7fffffffu;
}

double footprintMb() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info),
                &count) != KERN_SUCCESS) {
    return 0;
  }
  return static_cast<double>(info.phys_footprint) / 1e6;
}

// What the render block and the parameter blocks reach, without
// Objective-C objects; the read-only values live here because a value
// provider must not ask the parameter for its value.
struct RenderState {
  // The engine as the render block sees it and the renders in flight:
  // dealloc takes the engine away and waits for them, so that a render
  // racing it never touches a freed engine or buffer.
  std::atomic<AudAuv3Engine*> engine{nullptr};
  std::atomic<int32_t> rendering{0};
  float* buffers[2] = {nullptr, nullptr};
  std::atomic<float> footprint{0};
  std::atomic<float> firstFrame{0};
};

}  // namespace

@implementation AudSpikeAudioUnit {
  AudAuv3Engine* _engine;
  AUAudioUnitBus* _outputBus;
  AUAudioUnitBusArray* _outputBusses;
  AUParameterTree* _tree;
  AUParameter* _footprint;
  AUParameter* _firstFrame;
  RenderState* _state;
  NSTimer* _footprintTimer;
}

+ (AUParameterAddress)footprintAddress {
  return stableId("spike/footprint");
}

+ (AUParameterAddress)firstFrameAddress {
  return stableId("spike/firstFrame");
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError**)outError {
  self = [super initWithComponentDescription:description options:options error:outError];
  if (self == nil) return nil;
  ensureBallast();
  _engine = aud_auv3_engine_create(48000, kMaxFrames);
  if (_engine == nullptr) {
    if (outError != nullptr) {
      *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:-1 userInfo:nil];
    }
    return nil;
  }
  _state = new RenderState();
  _state->engine.store(_engine, std::memory_order_release);
  AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000
                                                                         channels:2];
  _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
  _outputBus.maximumChannelCount = 2;
  _outputBusses = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                          busType:AUAudioUnitBusTypeOutput
                                                           busses:@[ _outputBus ]];
  self.maximumFramesToRender = kMaxFrames;

  NSMutableArray<AUParameter*>* parameters = [NSMutableArray array];
  const uint32_t count = aud_auv3_engine_num_params(_engine);
  for (uint32_t i = 0; i < count; ++i) {
    AudAuv3Param p{};
    if (aud_auv3_engine_param(_engine, i, &p) == 0) continue;
    const bool hertz = std::strcmp(p.unit, "Hz") == 0;
    const bool stepped = (p.flags & (1u << 2)) != 0 && p.steps >= 2;
    AudioUnitParameterOptions flags =
        kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable;
    if ((p.flags & (1u << 3)) != 0) flags |= kAudioUnitParameterFlag_DisplayLogarithmic;
    AUParameter* parameter = [AUParameterTree
        createParameterWithIdentifier:[NSString stringWithFormat:@"%s_%s", p.nodeId,
                                                                 p.paramId]
                                 name:[NSString stringWithFormat:@"%s %s", p.nodeId, p.name]
                              address:p.id
                                  min:p.min
                                  max:p.max
                                 unit:hertz ? kAudioUnitParameterUnit_Hertz
                                            : (stepped ? kAudioUnitParameterUnit_Indexed
                                                       : kAudioUnitParameterUnit_Generic)
                             unitName:nil
                                flags:flags
                         valueStrings:nil
                  dependentParameters:nil];
    parameter.value = p.defaultValue;
    [parameters addObject:parameter];
  }
  const AudioUnitParameterOptions readOnly =
      kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_MeterReadOnly;
  _footprint = [AUParameterTree createParameterWithIdentifier:@"spike_footprint"
                                                         name:@"Footprint (MB)"
                                                      address:AudSpikeAudioUnit.footprintAddress
                                                          min:0
                                                          max:4096
                                                         unit:kAudioUnitParameterUnit_Generic
                                                     unitName:@"MB"
                                                        flags:readOnly
                                                 valueStrings:nil
                                          dependentParameters:nil];
  _firstFrame = [AUParameterTree createParameterWithIdentifier:@"spike_first_frame"
                                                          name:@"First frame (ms)"
                                                       address:AudSpikeAudioUnit.firstFrameAddress
                                                           min:0
                                                           max:60000
                                                          unit:kAudioUnitParameterUnit_Milliseconds
                                                      unitName:nil
                                                         flags:readOnly
                                                  valueStrings:nil
                                           dependentParameters:nil];
  [parameters addObject:_footprint];
  [parameters addObject:_firstFrame];
  _tree = [AUParameterTree createTreeWithChildren:parameters];
  AudAuv3Engine* engine = _engine;
  const AUParameterAddress footprintAddress = AudSpikeAudioUnit.footprintAddress;
  const AUParameterAddress firstFrameAddress = AudSpikeAudioUnit.firstFrameAddress;
  _tree.implementorValueObserver = ^(AUParameter* parameter, AUValue value) {
    if (parameter.address == footprintAddress || parameter.address == firstFrameAddress) {
      return;
    }
    aud_auv3_engine_set_param(engine, static_cast<uint32_t>(parameter.address), value);
  };
  RenderState* state = _state;
  _tree.implementorValueProvider = ^AUValue(AUParameter* parameter) {
    if (parameter.address == footprintAddress) return state->footprint.load();
    if (parameter.address == firstFrameAddress) return state->firstFrame.load();
    return aud_auv3_engine_get_param(engine, static_cast<uint32_t>(parameter.address));
  };
  __weak AudSpikeAudioUnit* weakSelf = self;
  _footprintTimer = [NSTimer timerWithTimeInterval:1.0
                                           repeats:YES
                                             block:^(NSTimer* timer) {
                                               [weakSelf publishFootprint];
                                             }];
  [[NSRunLoop mainRunLoop] addTimer:_footprintTimer forMode:NSRunLoopCommonModes];
  [self publishFootprint];
  return self;
}

- (void)dealloc {
  [_footprintTimer invalidate];
  if (_state != nullptr) {
    // Sequentially consistent, as in the render block: each side stores,
    // then loads what the other stores.
    _state->engine.store(nullptr, std::memory_order_seq_cst);
    while (_state->rendering.load(std::memory_order_seq_cst) != 0) {
      std::this_thread::yield();
    }
  }
  aud_auv3_engine_destroy(_engine);
  if (_state != nullptr) {
    std::free(_state->buffers[0]);
    std::free(_state->buffers[1]);
    delete _state;
  }
}

- (void)publishFootprint {
  const AUValue value = static_cast<AUValue>(footprintMb());
  // Also in the device log, for hosts that show no parameter (GarageBand).
  NSLog(@"aud_auv3 footprint %.1f MB", value);
  _state->footprint.store(value);
  [_footprint setValue:value originator:nil];
}

- (void)reportFirstFrame:(double)milliseconds {
  const AUValue value = static_cast<AUValue>(milliseconds);
  _state->firstFrame.store(value);
  [_firstFrame setValue:value originator:nil];
}

- (AudAuv3Engine*)engine {
  return _engine;
}

- (AUAudioUnitBusArray*)outputBusses {
  return _outputBusses;
}

- (AUParameterTree*)parameterTree {
  return _tree;
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError**)outError {
  if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
  const AUAudioFrameCount frames = std::max<AUAudioFrameCount>(self.maximumFramesToRender, 1);
  for (float*& buffer : _state->buffers) {
    std::free(buffer);
    buffer = static_cast<float*>(std::calloc(frames, sizeof(float)));
  }
  aud_auv3_engine_prepare(_engine, _outputBus.format.sampleRate, frames);
  aud_auv3_engine_set_active(_engine, 1);
  return YES;
}

- (void)deallocateRenderResources {
  aud_auv3_engine_set_active(_engine, 0);
  [super deallocateRenderResources];
}

- (AUInternalRenderBlock)internalRenderBlock {
  RenderState* state = _state;
  return ^AUAudioUnitStatus(AudioUnitRenderActionFlags* actionFlags,
                            const AudioTimeStamp* timestamp,
                            AUAudioFrameCount frames, NSInteger outputBusNumber,
                            AudioBufferList* outputData,
                            const AURenderEvent* events,
                            AURenderPullInputBlock pullInputBlock) {
    state->rendering.fetch_add(1, std::memory_order_seq_cst);
    AudAuv3Engine* engine = state->engine.load(std::memory_order_seq_cst);
    if (engine == nullptr) {
      state->rendering.fetch_sub(1, std::memory_order_release);
      *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
      return noErr;
    }
    for (const AURenderEvent* event = events; event != nullptr; event = event->head.next) {
      if (event->head.eventType == AURenderEventParameter ||
          event->head.eventType == AURenderEventParameterRamp) {
        aud_auv3_engine_push_param(engine,
                                   static_cast<uint32_t>(event->parameter.parameterAddress),
                                   event->parameter.value);
      }
    }
    float* outputs[2] = {nullptr, nullptr};
    const UInt32 channels = std::min<UInt32>(outputData->mNumberBuffers, 2);
    for (UInt32 i = 0; i < channels; ++i) {
      if (outputData->mBuffers[i].mData == nullptr) {
        outputData->mBuffers[i].mData = state->buffers[i];
      }
      outputData->mBuffers[i].mDataByteSize = frames * sizeof(float);
      outputs[i] = static_cast<float*>(outputData->mBuffers[i].mData);
    }
    aud_auv3_engine_render(engine, outputs, channels, frames);
    state->rendering.fetch_sub(1, std::memory_order_release);
    return noErr;
  };
}

@end
