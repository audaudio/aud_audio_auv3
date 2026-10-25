// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#import "aud_auv3_audio_unit.h"

#import <AVFoundation/AVFoundation.h>

#include <mach/mach_time.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "aud_spsc_queue.hpp"

#include "aud_auv3_config.hpp"
#include "aud_auv3_events.hpp"

using namespace aud_auv3;

namespace {

constexpr double kDefaultSampleRate = 48000;
constexpr AUAudioFrameCount kDefaultMaxFrames = 4096;

// The events of one block the graph takes at most.
constexpr uint32_t kMaxEvents = 1024;

// How long an offline block waits at most for a preset to load.
constexpr uint32_t kOfflineLoadMs = 30'000;

// Nanoseconds per tick of mach_absolute_time.
const double kTickNs = [] {
  mach_timebase_info_data_t timebase{};
  mach_timebase_info(&timebase);
  return static_cast<double>(timebase.numer) / timebase.denom;
}();

// The key of the shell's state in fullState.
NSString* const kStateKey = @"aud_state";

// A MIDI message of the editor on its way to the render thread.
struct EditorMidi {
  uint8_t status;
  uint8_t data1;
  uint8_t data2;
};

// The stable id of the parameter "Preset", the one of the VST3 shell.
uint32_t presetParamId() {
  static const uint32_t id = aud_host_param_id("shell", "preset");
  return id;
}

// Where the extension keeps the app's configuration: aud_plugin in its
// resources (Contents/Resources on macOS, the bundle itself on iOS).
std::string settingsDirectory() {
  return std::string([NSBundle mainBundle].resourcePath.UTF8String) + "/aud_plugin";
}

// The sample cache of the extension process, shared by all its instances.
void setCacheBudget() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    aud_cache_set_budget(static_cast<uint64_t>(AUD_AUV3_CACHE_BUDGET_MB) << 20);
  });
}

NSError* errorOf(const std::string& message) {
  return [NSError errorWithDomain:@"aud_audio_auv3"
                             code:kAudioUnitErr_FailedInitialization
                         userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
}

// What the render block works on; the unit owns it, the block points to it.
struct RenderState {
  Engine* engine = nullptr;
  const Settings* settings = nullptr;
  std::atomic<bool> offline{false};
  std::atomic<int32_t>* preset = nullptr;
  std::atomic<float>* controlValues = nullptr;
  std::atomic<bool>* controlDirty = nullptr;
  AudSpscQueue<EditorMidi> editorMidi{256};
  AUHostMusicalContextBlock musicalContext = nil;
  AUHostTransportStateBlock transportState = nil;
  AUMIDIOutputEventBlock midiOutput = nil;
  AUMIDIEventListBlock midiOutputList = nil;
  AUAudioFrameCount maxFrames = kDefaultMaxFrames;
  std::vector<float> scratch;
  TransportClock clock;
  AudTransportSegment segment{};
  AudTransportSnapshot snapshot{};
  AudEvent events[kMaxEvents];
  uint32_t numEvents = 0;

  // The render meter: blocks, the realtime ones that took more than 3/4 of
  // their duration, the slowest in host ticks, the last block's size, buffers
  // and rate; the main thread reads and resets it.
  std::atomic<uint64_t> blocks{0};
  std::atomic<uint64_t> late{0};
  std::atomic<uint64_t> slowestTicks{0};
  std::atomic<uint32_t> lastFrames{0};
  std::atomic<uint32_t> lastBuffers{0};
  std::atomic<uint32_t> lastChannelsPerBuffer{0};
  std::atomic<double> sampleRate{kDefaultSampleRate};

  void add(const AudEvent& event) AUD_PLUGIN_NONBLOCKING {
    if (numEvents < kMaxEvents) events[numEvents++] = event;
  }

  int32_t controlIndex(uint32_t id) const {
    for (size_t i = 0; i < settings->controls.size(); ++i) {
      if (settings->controls[i].paramId == id) return static_cast<int32_t>(i);
    }
    return -1;
  }
};

// Hands a note of the editor to the host's MIDI output at the block's
// start.
void sendMidi(const RenderState& state, const EditorMidi& midi,
              Float64 sampleTime) AUD_PLUGIN_NONBLOCKING {
  const auto time = static_cast<AUEventSampleTime>(sampleTime);
  if (state.midiOutput != nil) {
    uint8_t bytes[3];
    const uint32_t length = midiOutputBytes(midi.status, midi.data1, midi.data2, bytes);
    if (length > 0) state.midiOutput(time, 0, length, bytes);
  } else if (state.midiOutputList != nil) {
    const uint32_t word = midiOutputUmp(midi.status, midi.data1, midi.data2);
    if (word == 0) return;
    MIDIEventList list{};
    list.protocol = kMIDIProtocol_1_0;
    list.numPackets = 1;
    list.packet[0].timeStamp = 0;
    list.packet[0].wordCount = 1;
    list.packet[0].words[0] = word;
    state.midiOutputList(time, 0, &list);
  }
}

}  // namespace

// #############################################################################
@implementation AudAuv3AudioUnit {
  Settings _settings;
  std::unique_ptr<Engine> _engine;
  std::unique_ptr<RenderState> _render;
  std::atomic<int32_t> _preset;
  std::unique_ptr<std::atomic<float>[]> _controlValues;
  std::unique_ptr<std::atomic<bool>[]> _controlDirty;
  // Set while the unit itself sets parameter values, which the tree's
  // observer must not hand back to the engine.
  std::atomic<bool> _echo;
  std::shared_ptr<std::atomic<bool>> _alive;
  dispatch_source_t _meter;
  AUAudioUnitBus* _outputBus;
  AUAudioUnitBusArray* _outputBusArray;
  AUParameterTree* _tree;
  NSArray<AUAudioUnitPreset*>* _factoryPresets;
  AUAudioUnitPreset* _currentPreset;
  NSArray<NSString*>* _presetNames;
  NSString* _editorSettings;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError**)outError {
  self = [super initWithComponentDescription:description options:options error:outError];
  if (self == nil) return nil;
  std::string error;
  const std::string directory = settingsDirectory();
  if (!readSettings(directory, &_settings, &error)) {
    logError("The plugin's settings do not read: " + error);
    if (outError != nullptr) *outError = errorOf(error);
    return nil;
  }
  std::string content;
  if (!_settings.content.empty()) {
    content = contentDirectory(_settings.content, [NSBundle mainBundle].bundlePath.UTF8String);
    if (content.empty()) {
      logError("The content of " + _settings.name + " is missing");
      if (outError != nullptr) *outError = errorOf("The content is missing");
      return nil;
    }
  }
  setCacheBudget();
  setVoiceBudget(_settings.voiceBudget);
  _engine = std::make_unique<Engine>();
  if (!_engine->open(_settings.document, content, kDefaultSampleRate, kDefaultMaxFrames,
                     &error)) {
    logError("The document of " + _settings.name + " does not load: " + error);
    if (outError != nullptr) *outError = errorOf(error);
    return nil;
  }
  _alive = std::make_shared<std::atomic<bool>>(true);
  _preset.store(static_cast<int32_t>(_settings.defaultPreset));
  _controlValues = std::make_unique<std::atomic<float>[]>(_settings.controls.size());
  _controlDirty = std::make_unique<std::atomic<bool>[]>(_settings.controls.size());
  for (size_t i = 0; i < _settings.controls.size(); ++i) {
    // Untouched: a control sends nothing until it moves, so that what the
    // preset sets holds.
    _controlValues[i].store(std::nanf(""));
    _controlDirty[i].store(false);
  }
  _editorSettings = @"";

  AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kDefaultSampleRate
                                                                         channels:2];
  _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
  if (_outputBus == nil) return nil;
  _outputBus.maximumChannelCount = 2;
  _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                           busType:AUAudioUnitBusTypeOutput
                                                            busses:@[ _outputBus ]];
  [self makePresets];
  [self makeParameterTree];

  _render = std::make_unique<RenderState>();
  _render->engine = _engine.get();
  _render->settings = &_settings;
  _render->preset = &_preset;
  _render->controlValues = _controlValues.get();
  _render->controlDirty = _controlDirty.get();
  _render->clock = TransportClock(_settings.freeRunningTransport);

  // A preset applied on the engine's control thread: the host hears the
  // new values on the main thread.
  __weak AudAuv3AudioUnit* weakSelf = self;
  std::shared_ptr<std::atomic<bool>> alive = _alive;
  _engine->setPresets(&_settings.presets, [weakSelf, alive](uint32_t index) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!alive->load()) return;
      [weakSelf presetApplied:index];
    });
  });
  if (!_settings.presets.empty()) {
    _engine->applyPreset(_settings.presets[_settings.defaultPreset], &error);
  }
  self.maximumFramesToRender = kDefaultMaxFrames;
  logInfo(_settings.name + " is ready, content in " + content);
  return self;
}

- (void)dealloc {
  if (_alive) _alive->store(false);
  if (_meter != nil) dispatch_source_cancel(_meter);
}

// .............................................................................
- (void)makePresets {
  NSMutableArray<AUAudioUnitPreset*>* presets = [NSMutableArray array];
  NSMutableArray<NSString*>* names = [NSMutableArray array];
  NSInteger number = 0;
  for (const ShellPreset& shellPreset : _settings.presets) {
    AUAudioUnitPreset* preset = [[AUAudioUnitPreset alloc] init];
    preset.number = number++;
    preset.name = @(shellPreset.name.c_str());
    [presets addObject:preset];
    [names addObject:preset.name];
  }
  _factoryPresets = presets;
  _presetNames = names;
  _currentPreset = presets.count > _settings.defaultPreset ? presets[_settings.defaultPreset] : nil;
}

- (void)makeParameterTree {
  NSMutableArray<AUParameterNode*>* children = [NSMutableArray array];
  const AudioUnitParameterOptions flags = kAudioUnitParameterFlag_IsReadable |
                                          kAudioUnitParameterFlag_IsWritable;
  if (!_settings.presets.empty()) {
    AUParameter* preset =
        [AUParameterTree createParameterWithIdentifier:@"preset"
                                                  name:@"Preset"
                                               address:presetParamId()
                                                   min:0
                                                   max:_settings.presets.size() - 1
                                                  unit:kAudioUnitParameterUnit_Indexed
                                              unitName:nil
                                                 flags:flags
                                          valueStrings:_presetNames
                                   dependentParameters:nil];
    preset.value = _settings.defaultPreset;
    [children addObject:preset];
  }
  for (const ShellParam& shellParam : _settings.params) {
    const EngineParam* param = _engine->param(shellParam.id);
    if (param == nullptr) {
      logError("The document has no parameter " + shellParam.node + "/" + shellParam.param);
      continue;
    }
    AudioUnitParameterOptions options = flags;
    if ((param->flags & AUD_PARAM_LOGARITHMIC) != 0) {
      options |= kAudioUnitParameterFlag_DisplayLogarithmic;
    }
    AUParameter* parameter = [AUParameterTree
        createParameterWithIdentifier:@((shellParam.node + "_" + shellParam.param).c_str())
                                 name:@(shellParam.name.c_str())
                              address:shellParam.id
                                  min:param->min
                                  max:param->max
                                 unit:kAudioUnitParameterUnit_CustomUnit
                             unitName:@(param->unit.c_str())
                                flags:options
                         valueStrings:nil
                  dependentParameters:nil];
    parameter.value = param->defaultValue;
    [children addObject:parameter];
  }
  for (const ShellControl& control : _settings.controls) {
    AUParameter* parameter =
        [AUParameterTree createParameterWithIdentifier:@(("control_" + control.id).c_str())
                                                  name:@(control.name.c_str())
                                               address:control.paramId
                                                   min:0
                                                   max:1
                                                  unit:kAudioUnitParameterUnit_Generic
                                              unitName:nil
                                                 flags:flags
                                          valueStrings:nil
                                   dependentParameters:nil];
    parameter.value = static_cast<AUValue>(control.defaultValue);
    [children addObject:parameter];
  }
  _tree = [AUParameterTree createTreeWithChildren:children];

  Engine* engine = _engine.get();
  const Settings* settings = &_settings;
  std::atomic<int32_t>* preset = &_preset;
  std::atomic<float>* controlValues = _controlValues.get();
  std::atomic<bool>* controlDirty = _controlDirty.get();
  std::atomic<bool>* echo = &_echo;
  __weak AudAuv3AudioUnit* weakSelf = self;
  _tree.implementorValueObserver = ^(AUParameter* param, AUValue value) {
    if (echo->load()) return;
    const uint32_t id = static_cast<uint32_t>(param.address);
    if (id == presetParamId()) {
      [weakSelf choosePreset:std::lround(value)];
      return;
    }
    for (size_t i = 0; i < settings->controls.size(); ++i) {
      if (settings->controls[i].paramId != id) continue;
      controlValues[i].store(std::min(1.0f, std::max(0.0f, value)));
      controlDirty[i].store(true);
      return;
    }
    if (engine->param(id) != nullptr) engine->setParam(id, value);
  };
  _tree.implementorValueProvider = ^AUValue(AUParameter* param) {
    const uint32_t id = static_cast<uint32_t>(param.address);
    if (id == presetParamId()) return static_cast<AUValue>(preset->load());
    for (size_t i = 0; i < settings->controls.size(); ++i) {
      if (settings->controls[i].paramId != id) continue;
      const float value = controlValues[i].load();
      return std::isfinite(value) ? value : static_cast<AUValue>(settings->controls[i].defaultValue);
    }
    return engine->param(id) != nullptr ? engine->value(id) : 0.0f;
  };
}

// .............................................................................
// [main] Applies the preset at `index` on the engine's control thread and
// waits for it, so that a parameter the host or the editor sets after it
// keeps its value; the render thread only requests a preset, it never
// waits. The host and the editor hear of it right after.
- (void)choosePreset:(long)index {
  if (index < 0 || static_cast<size_t>(index) >= _settings.presets.size()) return;
  _preset.store(static_cast<int32_t>(index));
  std::string error;
  if (!_engine->applyPreset(_settings.presets[static_cast<size_t>(index)], &error)) {
    logError(error);
  }
  [self presetApplied:static_cast<uint32_t>(index)];
}

// [main] A preset applied: the parameters, currentPreset and presetIndex
// show its values.
- (void)presetApplied:(uint32_t)index {
  _echo.store(true);
  [_tree parameterWithAddress:presetParamId()].value = index;
  for (const ShellParam& shellParam : _settings.params) {
    if (_engine->param(shellParam.id) == nullptr) continue;
    [_tree parameterWithAddress:shellParam.id].value = _engine->value(shellParam.id);
  }
  _echo.store(false);
  [self willChangeValueForKey:@"presetIndex"];
  [self willChangeValueForKey:@"currentPreset"];
  _currentPreset = index < _factoryPresets.count ? _factoryPresets[index] : nil;
  [self didChangeValueForKey:@"currentPreset"];
  [self didChangeValueForKey:@"presetIndex"];
}

- (void)selectPreset:(NSInteger)index {
  [self choosePreset:index];
}

- (NSInteger)presetIndex {
  return _preset.load();
}

- (NSArray<NSString*>*)presetNames {
  return _presetNames;
}

- (NSString*)editorSettings {
  return _editorSettings;
}

// New settings change the state: hosts that observe fullState or
// fullStateForDocument learn of it.
- (void)setEditorSettings:(NSString*)editorSettings {
  const NSUInteger bytes = [editorSettings lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if (bytes > kMaxEditorSettings) {
    logError("The editor's settings of " + std::to_string(bytes) + " bytes are longer than " +
             std::to_string(kMaxEditorSettings));
    return;
  }
  if ([editorSettings isEqualToString:_editorSettings]) return;
  [self willChangeValueForKey:@"fullState"];
  [self willChangeValueForKey:@"fullStateForDocument"];
  _editorSettings = [editorSettings copy];
  [self didChangeValueForKey:@"fullStateForDocument"];
  [self didChangeValueForKey:@"fullState"];
  logInfo("The editor's settings changed: " + std::to_string(bytes) + " bytes");
}

- (void)playEditorStatus:(uint8_t)status data1:(uint8_t)data1 data2:(uint8_t)data2 {
  _render->editorMidi.push({status, data1, data2});
}

// .............................................................................
// AUAudioUnit

- (AUAudioUnitBusArray*)outputBusses {
  return _outputBusArray;
}

- (AUParameterTree*)parameterTree {
  return _tree;
}

- (NSArray<NSString*>*)MIDIOutputNames {
  return @[ @"MIDI Out" ];
}

- (NSArray<NSNumber*>*)channelCapabilities {
  return @[ @0, @2 ];
}

- (BOOL)shouldChangeToFormat:(AVAudioFormat*)format forBus:(AUAudioUnitBus*)bus {
  return format.channelCount == 2 && [super shouldChangeToFormat:format forBus:bus];
}

- (NSArray<AUAudioUnitPreset*>*)factoryPresets {
  return _factoryPresets;
}

- (AUAudioUnitPreset*)currentPreset {
  return _currentPreset;
}

- (void)setCurrentPreset:(AUAudioUnitPreset*)currentPreset {
  if (currentPreset == nil || currentPreset.number < 0) return;
  [self choosePreset:currentPreset.number];
}

- (NSTimeInterval)latency {
  const double rate = _outputBus.format.sampleRate;
  return rate > 0 ? _engine->latency() / rate : 0;
}

- (NSTimeInterval)tailTime {
  const double rate = _outputBus.format.sampleRate;
  return rate > 0 ? _engine->tail() / rate : 0;
}

- (void)setRenderingOffline:(BOOL)renderingOffline {
  [super setRenderingOffline:renderingOffline];
  _render->offline.store(renderingOffline);
}

- (NSDictionary<NSString*, id>*)fullState {
  NSMutableDictionary<NSString*, id>* state = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
  ShellState saved;
  const int32_t index = _preset.load();
  if (index >= 0 && static_cast<size_t>(index) < _settings.presets.size()) {
    saved.preset = _settings.presets[static_cast<size_t>(index)].id;
  }
  for (const ShellParam& shellParam : _settings.params) {
    if (_engine->param(shellParam.id) == nullptr) continue;
    saved.params.emplace_back(shellParam.id, _engine->value(shellParam.id));
  }
  for (size_t i = 0; i < _settings.controls.size(); ++i) {
    const float value = _controlValues[i].load();
    if (std::isfinite(value)) saved.controls.emplace_back(_settings.controls[i].id, value);
  }
  saved.editor = _editorSettings.UTF8String;
  state[kStateKey] = @(encodeState(saved).c_str());
  logInfo("The host takes the state: preset " + saved.preset + ", " +
          std::to_string(saved.editor.size()) + " bytes of the editor's settings");
  return state;
}

- (void)setFullState:(NSDictionary<NSString*, id>*)fullState {
  [super setFullState:fullState];
  NSString* text = [fullState[kStateKey] isKindOfClass:[NSString class]] ? fullState[kStateKey] : nil;
  if (text == nil) {
    logInfo("The host restores a state without the shell's");
    return;
  }
  ShellState restored;
  std::string error;
  if (!decodeState(text.UTF8String, &restored, &error)) {
    logError("The state does not read: " + error);
    return;
  }
  logInfo("The host restores the state: preset " + restored.preset + ", " +
          std::to_string(restored.editor.size()) + " bytes of the editor's settings");
  // The preset first, its values after: the state's values are newer. A
  // preset the extension no longer has keeps the one that plays.
  const int32_t index = _settings.presetIndex(restored.preset);
  if (index >= 0) {
    if (!_engine->applyPreset(_settings.presets[static_cast<size_t>(index)], &error)) {
      logError(error);
    }
    _preset.store(index);
  }
  for (const auto& [id, plain] : restored.params) {
    if (_engine->param(id) != nullptr) _engine->setParam(id, plain);
  }
  for (const auto& [id, value] : restored.controls) {
    for (size_t i = 0; i < _settings.controls.size(); ++i) {
      if (_settings.controls[i].id != id) continue;
      _controlValues[i].store(static_cast<float>(std::min(1.0, std::max(0.0, value))));
      _controlDirty[i].store(true);
    }
  }
  _editorSettings = @(restored.editor.c_str());
  [self presetApplied:static_cast<uint32_t>(_preset.load())];
  _echo.store(true);
  for (size_t i = 0; i < _settings.controls.size(); ++i) {
    const float value = _controlValues[i].load();
    if (std::isfinite(value)) [_tree parameterWithAddress:_settings.controls[i].paramId].value = value;
  }
  _echo.store(false);
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError**)outError {
  if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
  const double rate = _outputBus.format.sampleRate;
  if (!_engine->prepare(rate, self.maximumFramesToRender) || !_engine->setActive(true)) {
    if (outError != nullptr) *outError = errorOf("The engine does not prepare");
    return NO;
  }
  _render->maxFrames = self.maximumFramesToRender;
  _render->scratch.assign(static_cast<size_t>(self.maximumFramesToRender) * 2, 0.0f);
  _render->musicalContext = self.musicalContextBlock;
  _render->transportState = self.transportStateBlock;
  _render->midiOutput = self.MIDIOutputEventBlock;
  _render->midiOutputList = nil;
  if (_render->midiOutput == nil) _render->midiOutputList = self.MIDIOutputEventListBlock;
  _render->clock.reset(rate);
  _render->sampleRate.store(rate);
  AVAudioFormat* format = _outputBus.format;
  logInfo(std::string("Render resources: ") + std::to_string(static_cast<int>(rate)) + " Hz, " +
          std::to_string(format.channelCount) + " channels" +
          (format.interleaved ? " interleaved" : "") +
          (format.commonFormat == AVAudioPCMFormatFloat32 ? "" : ", not float32") + ", at most " +
          std::to_string(self.maximumFramesToRender) + " frames");
  [self startMeter];
  return YES;
}

// Logs the render meter every 2 s while the unit renders: what a host's
// overloads come from shows in the unified log.
- (void)startMeter {
  if (_meter != nil) return;
  _meter = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(_meter, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                            2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
  RenderState* state = _render.get();
  std::shared_ptr<std::atomic<bool>> alive = _alive;
  dispatch_source_set_event_handler(_meter, ^{
    if (!alive->load()) return;
    const uint64_t blocks = state->blocks.exchange(0);
    if (blocks == 0) return;
    const uint64_t late = state->late.exchange(0);
    const double slowest = state->slowestTicks.exchange(0) * kTickNs / 1e6;
    const uint32_t frames = state->lastFrames.load();
    const double rate = state->sampleRate.load();
    char line[240];
    std::snprintf(line, sizeof(line),
                  "Render: %llu blocks of %u frames at %.0f Hz in %u buffers of %u channels, "
                  "slowest %.2f ms of %.2f ms, %llu late",
                  static_cast<unsigned long long>(blocks), frames, rate,
                  state->lastBuffers.load(), state->lastChannelsPerBuffer.load(), slowest,
                  frames / rate * 1000, static_cast<unsigned long long>(late));
    (late > 0 ? logError : logInfo)(line);
  });
  dispatch_resume(_meter);
}

- (void)deallocateRenderResources {
  _engine->setActive(false);
  _render->musicalContext = nil;
  _render->transportState = nil;
  _render->midiOutput = nil;
  _render->midiOutputList = nil;
  [super deallocateRenderResources];
}

- (AUInternalRenderBlock)internalRenderBlock {
  RenderState* state = _render.get();
  return ^AUAudioUnitStatus(AudioUnitRenderActionFlags* actionFlags, const AudioTimeStamp* timestamp,
                            AUAudioFrameCount frames, NSInteger outputBusNumber,
                            AudioBufferList* output, const AURenderEvent* realtimeEventListHead,
                            AURenderPullInputBlock pullInputBlock) AUD_PLUGIN_NONBLOCKING {
    (void)actionFlags;
    (void)outputBusNumber;
    (void)pullInputBlock;
    if (frames > state->maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
    const uint64_t started = mach_absolute_time();
    Engine* engine = state->engine;
    state->numEvents = 0;

    // What arrived from other threads: the editor's notes and the controls
    // a host or a restored state moved, at the block's start.
    EditorMidi midi{};
    while (state->editorMidi.pop(midi)) {
      state->add(midiEvent(midi.status, midi.data1, midi.data2, 0));
      sendMidi(*state, midi, timestamp->mSampleTime);
    }
    for (size_t i = 0; i < state->settings->controls.size(); ++i) {
      if (!state->controlDirty[i].exchange(false)) continue;
      const ShellControl& control = state->settings->controls[i];
      state->add(controlChangeEvent(control.channel, control.cc,
                                    sevenBits(state->controlValues[i].load()), 0));
    }

    // The host's events at their sample offsets.
    const double blockTime = timestamp->mSampleTime;
    for (const AURenderEvent* e = realtimeEventListHead; e != nullptr; e = e->head.next) {
      switch (e->head.eventType) {
        case AURenderEventMIDI: {
          AudEvent event{};
          const uint32_t offset = sampleOffset(e->MIDI.eventSampleTime, blockTime, frames);
          if (midiBytesEvent(e->MIDI.data, e->MIDI.length, offset, &event)) state->add(event);
          break;
        }
        case AURenderEventMIDIEventList: {
          const uint32_t offset =
              sampleOffset(e->MIDIEventsList.eventSampleTime, blockTime, frames);
          const MIDIEventList& list = e->MIDIEventsList.eventList;
          const MIDIEventPacket* packet = &list.packet[0];
          for (UInt32 p = 0; p < list.numPackets; ++p) {
            state->numEvents += umpEvents(packet->words, packet->wordCount, offset,
                                          state->events + state->numEvents,
                                          kMaxEvents - state->numEvents);
            packet = MIDIEventPacketNext(packet);
          }
          break;
        }
        case AURenderEventParameter:
        case AURenderEventParameterRamp: {
          const uint32_t id = static_cast<uint32_t>(e->parameter.parameterAddress);
          const AUValue value = e->parameter.value;
          if (id == presetParamId()) {
            const int32_t index = static_cast<int32_t>(std::lround(value));
            if (index >= 0 && static_cast<size_t>(index) < state->settings->presets.size() &&
                index != state->preset->load()) {
              state->preset->store(index);
              engine->requestPreset(static_cast<uint32_t>(index));
            }
            break;
          }
          const int32_t control = state->controlIndex(id);
          if (control >= 0) {
            const ShellControl& c = state->settings->controls[static_cast<size_t>(control)];
            const uint32_t offset = sampleOffset(e->parameter.eventSampleTime, blockTime, frames);
            state->add(controlChangeEvent(c.channel, c.cc, sevenBits(value), offset));
            state->controlValues[control].store(value);
            break;
          }
          if (engine->param(id) != nullptr) engine->pushParam(id, value);
          break;
        }
        default:
          break;
      }
    }

    // The host's transport.
    HostMusicalContext context;
    if (state->musicalContext != nil) {
      NSInteger denominator = 4;
      context.valid = state->musicalContext(&context.tempo, &context.numerator, &denominator,
                                            &context.beat, nullptr, &context.downbeat);
      context.denominator = denominator;
    }
    HostTransportState transport;
    if (state->transportState != nil) {
      AUHostTransportStateFlags flags = 0;
      transport.valid = state->transportState(&flags, nullptr, &transport.cycleStart,
                                              &transport.cycleEnd);
      transport.moving = (flags & AUHostTransportStateMoving) != 0;
      transport.cycling = (flags & AUHostTransportStateCycling) != 0;
    }
    state->clock.advance(hostTransportOf(context, transport), frames, &state->segment);
    state->snapshot = AudTransportSnapshot{};
    state->snapshot.struct_size = sizeof(AudTransportSnapshot);
    state->snapshot.capabilities = AUD_TRANSPORT_CAP_TEMPO | AUD_TRANSPORT_CAP_SEEK |
                                   AUD_TRANSPORT_CAP_START_STOP |
                                   AUD_TRANSPORT_CAP_TIME_SIGNATURE | AUD_TRANSPORT_CAP_LOOP;
    state->snapshot.num_segments = 1;
    state->snapshot.segments = &state->segment;

    // Offline the block waits for its changes and for the instrument of its
    // preset; the realtime path never waits.
    const bool offline = state->offline.load(std::memory_order_relaxed);
    if (offline) {
      engine->waitForParams();
      engine->waitForPreset(kOfflineLoadMs);
    }

    float* channels[2];
    for (UInt32 c = 0; c < 2; ++c) {
      AudioBuffer& buffer = output->mBuffers[std::min<UInt32>(c, output->mNumberBuffers - 1)];
      if (buffer.mData == nullptr) buffer.mData = state->scratch.data() + c * state->maxFrames;
      buffer.mDataByteSize = frames * sizeof(float);
      channels[c] = static_cast<float*>(buffer.mData);
    }
    EngineBlock block;
    block.outputs = channels;
    block.channels = output->mNumberBuffers >= 2 ? 2 : 1;
    block.frames = frames;
    block.offline = offline;
    block.events = state->events;
    block.numEvents = state->numEvents;
    block.transport = &state->snapshot;
    engine->render(block);

    const uint64_t ticks = mach_absolute_time() - started;
    state->blocks.fetch_add(1, std::memory_order_relaxed);
    state->lastFrames.store(frames, std::memory_order_relaxed);
    state->lastBuffers.store(output->mNumberBuffers, std::memory_order_relaxed);
    state->lastChannelsPerBuffer.store(output->mBuffers[0].mNumberChannels,
                                       std::memory_order_relaxed);
    if (ticks > state->slowestTicks.load(std::memory_order_relaxed)) {
      state->slowestTicks.store(ticks, std::memory_order_relaxed);
    }
    // Offline a block may wait for its preset; only realtime ones are late.
    if (!offline &&
        static_cast<double>(ticks) * kTickNs >
            frames / state->sampleRate.load(std::memory_order_relaxed) * 0.75e9) {
      state->late.fetch_add(1, std::memory_order_relaxed);
    }
    return noErr;
  };
}

@end
