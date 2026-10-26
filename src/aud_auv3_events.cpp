// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_auv3_events.hpp"

#include <cmath>

#include "aud_ump.h"

namespace aud_auv3 {

// #############################################################################
uint32_t sampleOffset(int64_t eventTime, double blockTime, uint32_t frames) {
  if (frames == 0) return 0;
  const double offset = static_cast<double>(eventTime) - blockTime;
  if (!(offset > 0)) return 0;
  if (offset >= frames) return frames - 1;
  return static_cast<uint32_t>(offset);
}

// #############################################################################
bool midiBytesEvent(const uint8_t* bytes, uint32_t length, uint32_t offset,
                    AudEvent* out) {
  if (bytes == nullptr || length == 0) return false;
  const uint32_t status = bytes[0];
  const uint32_t data = midiDataBytes(status);
  if (data == 0 || length < 1 + data) return false;
  *out = midiEvent(status, bytes[1] & 0x7F, data > 1 ? bytes[2] & 0x7F : 0,
                   offset);
  return true;
}

// #############################################################################
uint32_t umpEvents(const uint32_t* words, uint32_t count, uint32_t offset,
                   AudEvent* out, uint32_t capacity) {
  uint32_t written = 0;
  uint32_t at = 0;
  while (at < count && written < capacity) {
    const uint32_t size = aud_ump_word_count(words[at]);
    if (size == 0 || at + size > count) break;
    out[written++] = aud_event_ump(&words[at], size, offset, 0);
    at += size;
  }
  return written;
}

// #############################################################################
HostTransport hostTransportOf(const HostMusicalContext& context,
                              const HostTransportState& state) {
  HostTransport host;
  if (context.valid) {
    host.tempoValid = std::isfinite(context.tempo) && context.tempo > 0;
    host.tempo = context.tempo;
    host.signatureValid = context.numerator >= 1 && context.denominator >= 1;
    host.numerator = static_cast<uint32_t>(std::lround(context.numerator));
    host.denominator = static_cast<uint32_t>(context.denominator);
    host.barValid = std::isfinite(context.downbeat);
    host.barStart = context.downbeat;
  }
  if (state.valid) {
    host.playing = state.moving;
    host.positionValid = context.valid && std::isfinite(context.beat);
    host.position = context.beat;
    host.looping = state.cycling && state.cycleEnd > state.cycleStart;
    host.loopStart = state.cycleStart;
    host.loopEnd = state.cycleEnd;
  }
  return host;
}

// #############################################################################
uint32_t midiOutputBytes(uint8_t status, uint8_t data1, uint8_t data2, uint8_t out[3]) {
  const uint32_t data = midiDataBytes(status);
  if (data == 0) return 0;
  out[0] = status;
  out[1] = data1 & 0x7F;
  out[2] = data > 1 ? data2 & 0x7F : 0;
  return 1 + data;
}

// #############################################################################
uint32_t midiOutputUmp(uint8_t status, uint8_t data1, uint8_t data2) {
  uint8_t bytes[3];
  if (midiOutputBytes(status, data1, data2, bytes) == 0) return 0;
  return (0x2u << 28) | (static_cast<uint32_t>(bytes[0]) << 16) |
         (static_cast<uint32_t>(bytes[1]) << 8) | bytes[2];
}

}  // namespace aud_auv3
