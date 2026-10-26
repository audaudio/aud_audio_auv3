// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// What an Audio Unit host hands the render block, as the graph takes it
// (aud_auv3_events.hpp).

#include "aud_auv3_events.hpp"

#include "aud_ump.h"
#include "aud_auv3_harness.hpp"

using namespace aud_auv3;
using aud_auv3_test::expectEqual;
using aud_auv3_test::expectNear;
using aud_auv3_test::group;
using aud_auv3_test::test;

int main() {
  group("sampleOffset", [] {
    test("is the distance from the block's start", [] {
      expectEqual(sampleOffset(1100, 1000, 256), 100u);
    });
    test("is 0 for a late or immediate event", [] {
      expectEqual(sampleOffset(900, 1000, 256), 0u);
      expectEqual(sampleOffset(1000, 1000, 256), 0u);
    });
    test("is the last frame for an event beyond the block", [] {
      expectEqual(sampleOffset(5000, 1000, 256), 255u);
    });
    test("is 0 for a block without frames", [] {
      expectEqual(sampleOffset(1100, 1000, 0), 0u);
    });
  });

  group("midiBytesEvent", [] {
    test("a note on at its offset", [] {
      const uint8_t bytes[] = {0x92, 60, 100};
      AudEvent event{};
      expectEqual(midiBytesEvent(bytes, 3, 17, &event), true);
      expectEqual(event.sample_offset, 17u);
      expectEqual(event.port, 0u);
      expectEqual((event.words[0] >> 16) & 0xFF, 0x92u);
      expectEqual((event.words[0] >> 8) & 0x7F, 60u);
      expectEqual(event.words[0] & 0x7F, 100u);
    });
    test("a program change with one data byte", [] {
      const uint8_t bytes[] = {0xC1, 5};
      AudEvent event{};
      expectEqual(midiBytesEvent(bytes, 2, 0, &event), true);
      expectEqual((event.words[0] >> 16) & 0xFF, 0xC1u);
      expectEqual((event.words[0] >> 8) & 0x7F, 5u);
    });
    test("refuses system messages, missing bytes and no status", [] {
      AudEvent event{};
      const uint8_t clock[] = {0xF8};
      const uint8_t shortNote[] = {0x90, 60};
      const uint8_t data[] = {60, 100, 0};
      expectEqual(midiBytesEvent(clock, 1, 0, &event), false);
      expectEqual(midiBytesEvent(shortNote, 2, 0, &event), false);
      expectEqual(midiBytesEvent(data, 3, 0, &event), false);
      expectEqual(midiBytesEvent(nullptr, 3, 0, &event), false);
    });
  });

  group("umpEvents", [] {
    test("splits a packet into its messages", [] {
      // A MIDI 1.0 note on (one word), a MIDI 2.0 note on (two words).
      uint32_t words[3];
      words[0] = aud_ump_midi1_word(0, 0x90, 60, 100);
      aud_ump_midi2_note(0, 1, 1, 62, 0x8000, 0, 0, &words[1]);
      AudEvent events[4];
      expectEqual(umpEvents(words, 3, 9, events, 4), 2u);
      expectEqual(aud_ump_word_count(events[0].words[0]), 1u);
      expectEqual(aud_ump_word_count(events[1].words[0]), 2u);
      expectEqual(events[1].words[1], words[2]);
      expectEqual(events[1].sample_offset, 9u);
      expectEqual(aud_ump_is_note_on(events[1].words[0], events[1].words[1]) != 0, true);
    });
    test("drops a message cut short and stops at the capacity", [] {
      uint32_t words[2];
      uint32_t spare[2];
      words[0] = aud_ump_midi1_word(0, 0x80, 60, 0);
      aud_ump_midi2_note(0, 0, 1, 64, 0x8000, 0, 0, spare);
      words[1] = spare[0];  // the first of 2 words, the second missing
      AudEvent events[4];
      expectEqual(umpEvents(words, 2, 0, events, 4), 1u);
      expectEqual(umpEvents(words, 2, 0, events, 0), 0u);
    });
  });

  group("hostTransportOf", [] {
    test("follows a moving host", [] {
      HostMusicalContext context;
      context.valid = true;
      context.tempo = 96;
      context.numerator = 3;
      context.denominator = 4;
      context.beat = 10.5;
      context.downbeat = 9;
      HostTransportState state;
      state.valid = true;
      state.moving = true;
      state.cycling = true;
      state.cycleStart = 8;
      state.cycleEnd = 16;
      const HostTransport host = hostTransportOf(context, state);
      expectEqual(host.tempoValid, true);
      expectNear(host.tempo, 96, 1e-9);
      expectEqual(host.playing, true);
      expectEqual(host.positionValid, true);
      expectNear(host.position, 10.5, 1e-9);
      expectEqual(host.barValid, true);
      expectNear(host.barStart, 9, 1e-9);
      expectEqual(host.signatureValid, true);
      expectEqual(host.numerator, 3u);
      expectEqual(host.denominator, 4u);
      expectEqual(host.looping, true);
      expectNear(host.loopEnd, 16, 1e-9);
    });
    test("knows nothing without the blocks", [] {
      const HostTransport host = hostTransportOf({}, {});
      expectEqual(host.tempoValid, false);
      expectEqual(host.playing, false);
      expectEqual(host.positionValid, false);
      expectEqual(host.looping, false);
    });
    test("a stopped host keeps its tempo, not its position", [] {
      HostMusicalContext context;
      context.valid = true;
      context.tempo = 140;
      HostTransportState state;
      state.valid = true;
      const HostTransport host = hostTransportOf(context, state);
      expectEqual(host.tempoValid, true);
      expectEqual(host.playing, false);
    });
    test("an empty cycle is no loop", [] {
      HostTransportState state;
      state.valid = true;
      state.cycling = true;
      state.cycleStart = 4;
      state.cycleEnd = 4;
      expectEqual(hostTransportOf({}, state).looping, false);
    });
  });

  group("midiOutputBytes", [] {
    test("a note on has 3 bytes", [] {
      uint8_t out[3] = {};
      expectEqual(midiOutputBytes(0x91, 60, 100, out), 3u);
      expectEqual(out[0], uint8_t{0x91});
      expectEqual(out[1], uint8_t{60});
      expectEqual(out[2], uint8_t{100});
    });
    test("channel pressure and program change have 2", [] {
      uint8_t out[3] = {};
      expectEqual(midiOutputBytes(0xD0, 64, 99, out), 2u);
      expectEqual(out[1], uint8_t{64});
      expectEqual(out[2], uint8_t{0});
      expectEqual(midiOutputBytes(0xC3, 5, 0, out), 2u);
    });
    test("data bytes keep 7 bits", [] {
      uint8_t out[3] = {};
      midiOutputBytes(0xB0, 0xFF, 0x80, out);
      expectEqual(out[1], uint8_t{0x7F});
      expectEqual(out[2], uint8_t{0});
    });
    test("a status without a channel voice message has none", [] {
      uint8_t out[3] = {};
      expectEqual(midiOutputBytes(0xF8, 0, 0, out), 0u);
      expectEqual(midiOutputBytes(0x40, 0, 0, out), 0u);
    });
  });

  group("midiOutputUmp", [] {
    test("a note off in group 0", [] {
      expectEqual(midiOutputUmp(0x82, 64, 0), 0x20824000u);
    });
    test("channel pressure without its second data byte", [] {
      expectEqual(midiOutputUmp(0xD5, 70, 99), 0x20D54600u);
    });
    test("none for a status without a channel voice message", [] {
      expectEqual(midiOutputUmp(0xFE, 0, 0), 0u);
    });
  });

  return aud_auv3_test::finish();
}
