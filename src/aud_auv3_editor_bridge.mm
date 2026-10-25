// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#import "aud_auv3_editor_bridge.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>
#include <unordered_map>
#include <utility>

#include "aud_auv3_editor_api.h"
#include "aud_auv3_shared.hpp"

using namespace aud_auv3;

namespace {

// The version of the shell protocol the bridge speaks (audShellProtocolVersion).
constexpr NSInteger kProtocolVersion = 3;

// A bridge and the receiver its editor connected.
struct Connection {
  __weak AudAuv3EditorBridge* bridge = nil;
  AudAuv3EditorReceiver receiver = nullptr;
};

std::mutex& registryMutex() {
  static std::mutex mutex;
  return mutex;
}

std::unordered_map<int64_t, Connection>& registry() {
  static std::unordered_map<int64_t, Connection> connections;
  return connections;
}

std::atomic<int64_t> nextInstance{1};

}  // namespace

@implementation AudAuv3EditorBridge {
  __weak AudAuv3AudioUnit* _unit;
  int64_t _instance;
  // The notes the editor holds: channel and pitch.
  std::set<std::pair<uint8_t, uint8_t>> _held;
  NSDate* _start;
  NSTimeInterval _helloAfter;
  BOOL _welcomed;
  BOOL _ended;
}

- (instancetype)initWithUnit:(AudAuv3AudioUnit*)unit {
  self = [super init];
  if (self == nil) return nil;
  _unit = unit;
  _instance = nextInstance.fetch_add(1);
  _start = [NSDate date];
  {
    std::lock_guard<std::mutex> lock(registryMutex());
    registry()[_instance].bridge = self;
  }
  [unit addObserver:self forKeyPath:@"presetIndex" options:0 context:nil];
  return self;
}

- (void)dealloc {
  [_unit removeObserver:self forKeyPath:@"presetIndex"];
  std::lock_guard<std::mutex> lock(registryMutex());
  registry().erase(_instance);
}

- (int64_t)instance {
  return _instance;
}

// Hands the editor `message` as JSON text it frees; nothing without a
// receiver.
- (void)send:(NSDictionary<NSString*, id>*)message {
  AudAuv3EditorReceiver receiver = nullptr;
  {
    std::lock_guard<std::mutex> lock(registryMutex());
    const auto it = registry().find(_instance);
    if (it != registry().end()) receiver = it->second.receiver;
  }
  if (receiver == nullptr) return;
  NSData* data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
  if (data == nil) return;
  char* text = static_cast<char*>(std::malloc(data.length + 1));
  std::memcpy(text, data.bytes, data.length);
  text[data.length] = '\0';
  receiver(text);
}

- (NSTimeInterval)helloAfter {
  return _helloAfter;
}

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
  AudAuv3AudioUnit* unit = _unit;
  if (!_welcomed || _ended || unit == nil) return;
  [self send:@{@"type" : @"preset", @"instance" : @0, @"index" : @(unit.presetIndex)}];
}

- (void)receive:(NSDictionary<NSString*, id>*)message {
  AudAuv3AudioUnit* unit = _unit;
  if (_ended || unit == nil) return;
  NSString* type = [message[@"type"] isKindOfClass:[NSString class]] ? message[@"type"] : @"";
  if ([type isEqualToString:@"hello"]) {
    _helloAfter = -[_start timeIntervalSinceNow];
    logInfo("The editor of instance " + std::to_string(_instance) + " said hello after " +
            std::to_string(static_cast<int>(_helloAfter * 1000)) + " ms");
    [self welcome:unit];
  } else if ([type isEqualToString:@"selectPreset"]) {
    [unit selectPreset:[message[@"index"] integerValue]];
  } else if ([type isEqualToString:@"midi"]) {
    [self play:message[@"bytes"] on:unit];
  } else if ([type isEqualToString:@"settings"]) {
    NSString* settings = message[@"settings"];
    if ([settings isKindOfClass:[NSString class]]) unit.editorSettings = settings;
  }
}

- (void)welcome:(AudAuv3AudioUnit*)unit {
  NSMutableArray* params = [NSMutableArray array];
  for (AUParameter* parameter in unit.parameterTree.allParameters) {
    if ([parameter.identifier isEqualToString:@"preset"]) continue;
    [params addObject:@{
      @"id" : @(parameter.address),
      @"nodeId" : parameter.identifier,
      @"paramId" : parameter.identifier,
      @"node" : @0,
      @"index" : @(params.count),
      @"name" : parameter.displayName ?: @"",
      @"unit" : parameter.unitName ?: @"",
      @"min" : @(parameter.minValue),
      @"max" : @(parameter.maxValue),
      @"default" : @(parameter.value),
      @"value" : @(parameter.value),
      @"logarithmic" : @((parameter.flags & kAudioUnitParameterFlag_DisplayLogarithmic) != 0),
      @"steps" : @0,
    }];
  }
  NSMutableArray* presets = [NSMutableArray array];
  for (AUAudioUnitPreset* preset in unit.factoryPresets) {
    [presets addObject:@{@"id" : @(preset.number).stringValue, @"name" : preset.name}];
  }
  [self send:@{
    @"type" : @"welcome",
    @"instance" : @0,
    @"name" : unit.audioUnitName ?: @"",
    @"params" : params,
    @"width" : @0,
    @"height" : @0,
    @"scale" : @1,
    @"version" : @(kProtocolVersion),
    @"presets" : presets,
    @"preset" : @(unit.presetIndex),
    @"settings" : unit.editorSettings,
  }];
  _welcomed = YES;
}

// Plays complete MIDI 1.0 messages; a note on adds the note to those the
// editor holds, a note off or a note on of velocity 0 removes it.
- (void)play:(NSArray*)bytes on:(AudAuv3AudioUnit*)unit {
  if (![bytes isKindOfClass:[NSArray class]]) return;
  NSUInteger at = 0;
  while (at < bytes.count) {
    const uint8_t status = static_cast<uint8_t>([bytes[at] unsignedIntValue]);
    const uint32_t data = midiDataBytes(status);
    // A message without a channel voice status, or cut short, ends it.
    if (data == 0 || at + data >= bytes.count) break;
    const uint8_t data1 = static_cast<uint8_t>([bytes[at + 1] unsignedIntValue] & 0x7F);
    const uint8_t data2 =
        data > 1 ? static_cast<uint8_t>([bytes[at + 2] unsignedIntValue] & 0x7F) : 0;
    const uint8_t channel = status & 0x0F;
    if ((status & 0xF0) == 0x90 && data2 > 0) {
      _held.insert({channel, data1});
    } else if ((status & 0xF0) == 0x80 || (status & 0xF0) == 0x90) {
      _held.erase({channel, data1});
    }
    [unit playEditorStatus:status data1:data1 data2:data2];
    at += 1 + data;
  }
}

- (void)end {
  if (_ended) return;
  _ended = YES;
  AudAuv3AudioUnit* unit = _unit;
  for (const auto& [channel, pitch] : _held) {
    [unit playEditorStatus:static_cast<uint8_t>(0x80 | channel) data1:pitch data2:0];
  }
  _held.clear();
  std::lock_guard<std::mutex> lock(registryMutex());
  registry().erase(_instance);
}

@end

// #############################################################################
// The C interface (aud_auv3_editor_api.h)

namespace {

AudAuv3EditorBridge* bridgeOf(int64_t instance) {
  std::lock_guard<std::mutex> lock(registryMutex());
  const auto it = registry().find(instance);
  return it != registry().end() ? it->second.bridge : nil;
}

}  // namespace

int32_t aud_auv3_editor_connect(int64_t instance, AudAuv3EditorReceiver receiver) {
  std::lock_guard<std::mutex> lock(registryMutex());
  const auto it = registry().find(instance);
  if (it == registry().end() || it->second.bridge == nil) return -1;
  it->second.receiver = receiver;
  return 0;
}

int32_t aud_auv3_editor_send(int64_t instance, const char* json) {
  if (json == nullptr || bridgeOf(instance) == nil) return -1;
  NSData* data = [NSData dataWithBytes:json length:std::strlen(json)];
  id message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![message isKindOfClass:[NSDictionary class]]) return -1;
  // The bridge and the unit are the main thread's; Flutter runs Dart on it.
  void (^deliver)(void) = ^{
    [bridgeOf(instance) receive:message];
  };
  if ([NSThread isMainThread]) {
    deliver();
  } else {
    dispatch_async(dispatch_get_main_queue(), deliver);
  }
  return 0;
}

void aud_auv3_editor_disconnect(int64_t instance) {
  std::lock_guard<std::mutex> lock(registryMutex());
  const auto it = registry().find(instance);
  if (it != registry().end()) it->second.receiver = nullptr;
}

void aud_auv3_editor_free(char* json) { std::free(json); }
