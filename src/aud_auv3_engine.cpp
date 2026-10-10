// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_auv3_engine.h"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <cmath>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "aud_audio_graph.h"
#include "aud_spsc_queue.hpp"

namespace {

// The graph the spike plays - the document of the VST3 plugin of
// aud_audio_vst3: oscillator, filter and mixer, with a tap for the meter.
const char* const kDocument = R"({
  "schema": 1,
  "name": "aud_audio_auv3 spike",
  "outputChannels": [2],
  "nodes": [
    { "id": "osc", "type": "aud.graph.oscillator",
      "preset": { "schema": 1, "type": "aud.graph.oscillator",
                  "params": { "frequency": 220, "amplitude": 0.2,
                              "waveform": 1 } } },
    { "id": "filter", "type": "aud.graph.filter",
      "preset": { "schema": 1, "type": "aud.graph.filter",
                  "params": { "cutoff": 1200, "resonance": 0.3,
                              "mode": 0 } } },
    { "id": "out", "type": "aud.graph.mixer",
      "inputChannels": [2, 2, 2, 2, 2, 2, 2, 2], "outputChannels": [2],
      "preset": { "schema": 1, "type": "aud.graph.mixer",
                  "params": { "master": 0.5 } } },
    { "id": "meter", "type": "aud.graph.tap" }
  ],
  "connections": [
    { "from": "osc", "to": "filter" },
    { "from": "filter", "to": "out" },
    { "from": "out", "to": "meter" },
    { "from": "meter", "to": "graph" }
  ]
})";

// How often the control thread reads the meter and takes notifications.
constexpr int64_t kMeterPeriodNs = 33'000'000;

// How long the control thread sleeps when nothing wakes it.
constexpr int64_t kIdleWaitNs = 10'000'000;

int64_t nowNs() {
  static const mach_timebase_info_data_t info = [] {
    mach_timebase_info_data_t i{};
    mach_timebase_info(&i);
    return i;
  }();
  return static_cast<int64_t>(mach_absolute_time() * info.numer / info.denom);
}

struct Param {
  AudAuv3Param info{};
  std::string nodeId;
  std::string paramId;
  std::string name;
  std::string unit;
};

struct ParamChange {
  uint32_t id;
  float value;
};

}  // namespace

struct AudAuv3Engine {
  AudAuv3Engine() : changes(1024), wake(dispatch_semaphore_create(0)) {
    nowNs();
    thread = std::thread([this] { loop(); });
  }

  ~AudAuv3Engine() {
    // Sequentially consistent, as in render(): each side stores, then loads
    // what the other stores, which acquire and release alone may reorder.
    rtHost.store(nullptr, std::memory_order_seq_cst);
    while (rendering.load(std::memory_order_seq_cst) != 0) {
      std::this_thread::yield();
    }
    run([this] {
      if (graph != nullptr) aud_graph_stop(graph);
      if (host != nullptr) aud_host_destroy(host);
      if (graph != nullptr) aud_graph_destroy(graph);
      host = nullptr;
      graph = nullptr;
    });
    {
      std::lock_guard<std::mutex> lock(mutex);
      stopping = true;
    }
    dispatch_semaphore_signal(wake);
    thread.join();
    while (dispatch_semaphore_wait(wake, DISPATCH_TIME_NOW) == 0) {
    }
    dispatch_release(wake);
  }

  bool open(double sampleRate, uint32_t maxFrames) {
    bool ok = false;
    run([&] {
      const uint32_t outputChannels[] = {2};
      AudGraphConfig config{};
      config.struct_size = sizeof(AudGraphConfig);
      config.sample_rate = sampleRate;
      config.max_frames = maxFrames;
      config.num_output_buses = 1;
      config.output_channels = outputChannels;
      graph = aud_graph_create(&config);
      if (graph == nullptr) return;
      host = aud_host_create(graph, nullptr);
      if (host == nullptr) return;
      if (aud_host_load(host, kDocument, std::strlen(kDocument)) != AUD_OK) return;
      meterNode = aud_host_node(host, "meter");
      collectParams();
      ok = true;
    });
    if (ok) rtHost.store(host, std::memory_order_seq_cst);
    return ok;
  }

  void collectParams() {
    const int32_t count = aud_host_num_params(host);
    params.reserve(static_cast<size_t>(std::max(count, 0)));
    for (int32_t i = 0; i < count; ++i) {
      AudHostParam p{};
      p.struct_size = sizeof(AudHostParam);
      if (aud_host_param(host, static_cast<uint32_t>(i), &p) != AUD_OK) continue;
      Param param;
      param.nodeId = p.node_id;
      param.paramId = p.param_id;
      param.name = p.descriptor->name != nullptr ? p.descriptor->name : p.param_id;
      param.unit = p.descriptor->unit != nullptr ? p.descriptor->unit : "";
      param.info.id = p.id;
      param.info.min = p.descriptor->min_value;
      param.info.max = p.descriptor->max_value;
      param.info.defaultValue = p.value;
      param.info.flags = p.descriptor->flags;
      param.info.steps = p.descriptor->steps;
      params.push_back(std::move(param));
    }
    // The strings live in the vector, which no longer grows.
    for (Param& param : params) {
      param.info.nodeId = param.nodeId.c_str();
      param.info.paramId = param.paramId.c_str();
      param.info.name = param.name.c_str();
      param.info.unit = param.unit.c_str();
    }
  }

  const Param* find(uint32_t id) const {
    for (const Param& param : params) {
      if (param.info.id == id) return &param;
    }
    return nullptr;
  }

  void setParam(uint32_t id, float value) {
    const Param* param = find(id);
    if (param == nullptr || host == nullptr) return;
    aud_host_set_param(host, id,
                       std::min(param->info.max, std::max(param->info.min, value)),
                       0);
  }

  void drain() {
    ParamChange change{};
    while (changes.pop(change)) setParam(change.id, change.value);
  }

  void readMeter() {
    if (graph == nullptr || meterNode <= 0) return;
    float peak = 0;
    float rms = 0;
    float peakRight = 0;
    float rmsRight = 0;
    aud_graph_tap_meter(graph, meterNode, 0, &peak, &rms);
    aud_graph_tap_meter(graph, meterNode, 1, &peakRight, &rmsRight);
    // A graph that blows up must not send NaN to the editor.
    const auto finite = [](float v) { return std::isfinite(v) ? v : 0.0f; };
    meterPeak.store(finite(std::max(peak, peakRight)), std::memory_order_relaxed);
    meterRms.store(finite(std::max(rms, rmsRight)), std::memory_order_relaxed);
    AudGraphNotification notifications[32];
    for (auto& n : notifications) n.struct_size = sizeof(AudGraphNotification);
    while (aud_graph_take_notifications(graph, notifications, 32) == 32) {
    }
  }

  void run(const std::function<void()>& task) {
    if (std::this_thread::get_id() == thread.get_id()) {
      task();
      return;
    }
    std::unique_lock<std::mutex> lock(mutex);
    tasks.push_back(task);
    const uint64_t ticket = ++queued;
    dispatch_semaphore_signal(wake);
    done.wait(lock, [&] { return finished >= ticket; });
  }

  void loop() {
    for (;;) {
      dispatch_semaphore_wait(wake, dispatch_time(DISPATCH_TIME_NOW, kIdleWaitNs));
      std::deque<std::function<void()>> batch;
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (stopping && tasks.empty()) break;
        batch.swap(tasks);
      }
      for (const auto& task : batch) task();
      if (!batch.empty()) {
        std::lock_guard<std::mutex> lock(mutex);
        finished += batch.size();
        done.notify_all();
      }
      drain();
      const int64_t now = nowNs();
      if (now - lastMeter >= kMeterPeriodNs) {
        lastMeter = now;
        readMeter();
      }
    }
  }

  AudGraph* graph = nullptr;
  AudHost* host = nullptr;
  std::atomic<AudHost*> rtHost{nullptr};
  std::atomic<int32_t> rendering{0};
  int32_t meterNode = 0;
  std::vector<Param> params;
  AudSpscQueue<ParamChange> changes;
  dispatch_semaphore_t wake;
  std::mutex mutex;
  std::condition_variable done;
  std::deque<std::function<void()>> tasks;
  uint64_t queued = 0;
  uint64_t finished = 0;
  bool stopping = false;
  std::atomic<float> meterPeak{0};
  std::atomic<float> meterRms{0};
  int64_t lastMeter = 0;
  std::thread thread;
};

extern "C" {

AudAuv3Engine* aud_auv3_engine_create(double sampleRate, uint32_t maxFrames) {
  auto* engine = new AudAuv3Engine();
  if (!engine->open(sampleRate, maxFrames)) {
    delete engine;
    return nullptr;
  }
  return engine;
}

void aud_auv3_engine_destroy(AudAuv3Engine* engine) { delete engine; }

uint32_t aud_auv3_engine_num_params(const AudAuv3Engine* engine) {
  return engine == nullptr ? 0 : static_cast<uint32_t>(engine->params.size());
}

int aud_auv3_engine_param(const AudAuv3Engine* engine, uint32_t index,
                          AudAuv3Param* out) {
  if (engine == nullptr || out == nullptr || index >= engine->params.size()) {
    return 0;
  }
  *out = engine->params[index].info;
  return 1;
}

int aud_auv3_engine_prepare(AudAuv3Engine* engine, double sampleRate,
                            uint32_t maxFrames) {
  if (engine == nullptr) return 0;
  bool ok = false;
  engine->run([&] {
    const bool running = aud_graph_state(engine->graph) == AUD_GRAPH_RUNNING;
    if (running) aud_graph_stop(engine->graph);
    ok = aud_graph_prepare(engine->graph, sampleRate, maxFrames) == AUD_OK;
    if (running) aud_graph_start(engine->graph);
  });
  return ok ? 1 : 0;
}

int aud_auv3_engine_set_active(AudAuv3Engine* engine, int active) {
  if (engine == nullptr) return 0;
  bool ok = false;
  engine->run([&] {
    const int32_t state = aud_graph_state(engine->graph);
    if (active != 0) {
      ok = state == AUD_GRAPH_RUNNING || aud_graph_start(engine->graph) == AUD_OK;
    } else {
      ok = state != AUD_GRAPH_RUNNING || aud_graph_stop(engine->graph) == AUD_OK;
    }
  });
  return ok ? 1 : 0;
}

void aud_auv3_engine_set_param(AudAuv3Engine* engine, uint32_t id, float value) {
  if (engine == nullptr) return;
  engine->run([&] {
    engine->drain();
    engine->setParam(id, value);
  });
}

float aud_auv3_engine_get_param(AudAuv3Engine* engine, uint32_t id) {
  float value = 0;
  if (engine == nullptr) return value;
  engine->run([&] {
    engine->drain();
    if (engine->host != nullptr) aud_host_get_param(engine->host, id, &value);
  });
  return value;
}

void aud_auv3_engine_push_param(AudAuv3Engine* engine, uint32_t id, float value) {
  if (engine == nullptr) return;
  engine->changes.push({id, value});
  dispatch_semaphore_signal(engine->wake);
}

void aud_auv3_engine_render(AudAuv3Engine* engine, float* const* outputs,
                            uint32_t channels, uint32_t frames) {
  engine->rendering.fetch_add(1, std::memory_order_seq_cst);
  AudHost* host = engine->rtHost.load(std::memory_order_seq_cst);
  if (host == nullptr) {
    engine->rendering.fetch_sub(1, std::memory_order_release);
    for (uint32_t c = 0; c < channels; ++c) {
      std::memset(outputs[c], 0, sizeof(float) * frames);
    }
    return;
  }
  AudAudioBus bus{sizeof(AudAudioBus), channels, outputs};
  AudRenderRequest request{};
  request.struct_size = sizeof(AudRenderRequest);
  request.frames = frames;
  request.num_output_buses = 1;
  request.outputs = &bus;
  AudHostRenderRequest hostRequest{};
  hostRequest.struct_size = sizeof(AudHostRenderRequest);
  hostRequest.request = &request;
  aud_host_render(host, &hostRequest);
  engine->rendering.fetch_sub(1, std::memory_order_release);
}

void aud_auv3_engine_meter(const AudAuv3Engine* engine, float* peak, float* rms) {
  if (engine == nullptr) return;
  if (peak != nullptr) *peak = engine->meterPeak.load(std::memory_order_relaxed);
  if (rms != nullptr) *rms = engine->meterRms.load(std::memory_order_relaxed);
}

}  // extern "C"
