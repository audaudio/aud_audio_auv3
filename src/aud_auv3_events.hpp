// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// What an Audio Unit host hands the render block, as the graph takes it
// (ticket 41): the sample offset of an event in the block, MIDI 1.0
// messages and UMP packets as events on the graph's event input (port 0),
// and the host's musical context and transport state as the host transport
// of aud_audio_plugin; and what the render block hands the host's MIDI
// output, as MIDI 1.0 bytes or a UMP word. Plain C++ without Apple's types,
// so that the native tests cover it; the realtime thread calls it, nothing
// allocates.

#ifndef AUD_AUV3_EVENTS_HPP
#define AUD_AUV3_EVENTS_HPP

#include <cstdint>

#include "aud_auv3_shared.hpp"

namespace aud_auv3 {

// #############################################################################
// The offset of an event at the host's sample time `eventTime` in a block
// of `frames` frames that starts at `blockTime`: 0 for an event late or
// immediate, the last frame for one beyond the block.
uint32_t sampleOffset(int64_t eventTime, double blockTime, uint32_t frames);

// #############################################################################
// Writes the event of a MIDI 1.0 channel voice message of `length` bytes
// to `out`; false for a message the graph does not take (system messages,
// a status byte missing, too few data bytes).
bool midiBytesEvent(const uint8_t* bytes, uint32_t length, uint32_t offset,
                    AudEvent* out);

// #############################################################################
// Writes the events of the UMP messages in `words` (a packet of a MIDI
// event list) to `out`, `capacity` at most, and returns how many. A
// message cut short by the packet's end is dropped.
uint32_t umpEvents(const uint32_t* words, uint32_t count, uint32_t offset,
                   AudEvent* out, uint32_t capacity);

// #############################################################################
// What the host's musical context block tells; `valid` is false when the
// host has none or the block returned NO.
struct HostMusicalContext {
  bool valid = false;
  double tempo = 120;
  double numerator = 4;
  int64_t denominator = 4;
  double beat = 0;
  double downbeat = 0;
};

// #############################################################################
// What the host's transport state block tells; `valid` as above.
struct HostTransportState {
  bool valid = false;
  bool moving = false;
  bool cycling = false;
  double cycleStart = 0;
  double cycleEnd = 0;
};

// #############################################################################
// The host transport of aud_audio_plugin from the two blocks: the position
// counts only while the host's transport moves, the bar starts at the
// downbeat, the loop is the cycle.
HostTransport hostTransportOf(const HostMusicalContext& context,
                              const HostTransportState& state);

// #############################################################################
// Writes the MIDI 1.0 channel voice message of `status`, `data1` and
// `data2` to `out` for a host's MIDI output and returns its length: 2 bytes
// for a program change or channel pressure, 3 for the others, 0 for a
// status that starts no channel voice message.
uint32_t midiOutputBytes(uint8_t status, uint8_t data1, uint8_t data2, uint8_t out[3]);

// #############################################################################
// The same message as the UMP word of a MIDI 1.0 channel voice message
// (message type 2) in group 0, for a host's MIDI event list; 0 for a status
// as above.
uint32_t midiOutputUmp(uint8_t status, uint8_t data1, uint8_t data2);

}  // namespace aud_auv3

#endif  // AUD_AUV3_EVENTS_HPP
