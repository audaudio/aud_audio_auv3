// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The engine of the spike's Audio Unit (ticket 24): the graph and its
// headless host (aud_audio_graph, plugin-002) behind a C API the
// Objective-C++ of the extension calls, with the threads the host demands -
// as the VST3 plugin of aud_audio_vst3 has them:
//
// - the render thread calls aud_auv3_engine_render and _push_param only;
// - one control thread per engine owns every [control] call of the graph
//   and the host; parameter changes of the render thread reach it through
//   a lock-free ring;
// - other threads hand their calls to the control thread and wait.
//
// scripts/build-engine.js builds it with the graph into a static library
// for iOS.

#ifndef AUD_AUV3_ENGINE_H
#define AUD_AUV3_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AudAuv3Engine AudAuv3Engine;

// A parameter of the graph document. The strings stay valid while the
// engine lives.
typedef struct AudAuv3Param {
  uint32_t id;  // the stable id: FNV-1a of "<node id>/<param id>"
  const char* nodeId;
  const char* paramId;
  const char* name;
  const char* unit;
  float min;
  float max;
  float defaultValue;
  uint32_t flags;  // AUD_PARAM_* of aud_audio_core
  uint32_t steps;
} AudAuv3Param;

// [non-realtime] Creates the engine with the spike's graph document; NULL
// on a failure.
AudAuv3Engine* aud_auv3_engine_create(double sampleRate, uint32_t maxFrames);

// [non-realtime] Destroys the engine; rendering must have stopped.
void aud_auv3_engine_destroy(AudAuv3Engine* engine);

// The parameters of the document, ordered by id.
uint32_t aud_auv3_engine_num_params(const AudAuv3Engine* engine);
int aud_auv3_engine_param(const AudAuv3Engine* engine, uint32_t index,
                          AudAuv3Param* out);

// [non-realtime] Prepares rendering for a sample rate and a block size.
int aud_auv3_engine_prepare(AudAuv3Engine* engine, double sampleRate,
                            uint32_t maxFrames);

// [non-realtime] Starts or stops rendering.
int aud_auv3_engine_set_active(AudAuv3Engine* engine, int active);

// [non-realtime] Sets and reads the plain value of a parameter.
void aud_auv3_engine_set_param(AudAuv3Engine* engine, uint32_t id, float value);
float aud_auv3_engine_get_param(AudAuv3Engine* engine, uint32_t id);

// [realtime] Hands a parameter change to the control thread.
void aud_auv3_engine_push_param(AudAuv3Engine* engine, uint32_t id,
                                float value);

// [realtime] Renders one block into planar channels.
void aud_auv3_engine_render(AudAuv3Engine* engine, float* const* outputs,
                            uint32_t channels, uint32_t frames);

// [any thread] The output meter as the control thread last read it.
void aud_auv3_engine_meter(const AudAuv3Engine* engine, float* peak,
                           float* rms);

#ifdef __cplusplus
}
#endif

#endif  // AUD_AUV3_ENGINE_H
