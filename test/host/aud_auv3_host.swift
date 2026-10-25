// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The test host of the AUv3 shell (ticket 41), as Logic Pro loads a unit:
// it finds the component, loads it out of process and checks the preset
// parameter and the factory presets, every preset sounding offline with a
// note on each of the MIDI channels 1 to 4, the state round trip with a
// moved control, two instances side by side, the time of realtime blocks
// and the editor's view. One JSON line per check on stdout; the exit code
// is 1 when one fails.
//
//   aud_auv3_host <type> <subtype> <manufacturer> [--presets n]
//     [--editor seconds]

import AVFoundation
import AppKit
import CoreAudioKit

func fourCC(_ s: String) -> FourCharCode {
  s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

var failed = false

func report(_ check: String, _ ok: Bool, _ fields: [String: Any] = [:]) {
  var all = fields
  all["check"] = check
  all["ok"] = ok
  if !ok { failed = true }
  let data = try! JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
  print(String(data: data, encoding: .utf8)!)
  fflush(stdout)
}

func wait(_ seconds: Double, until done: () -> Bool) {
  let start = Date()
  while !done() && Date().timeIntervalSince(start) < seconds {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  }
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
  print("usage: aud_auv3_host <type> <subtype> <manufacturer> [--presets n] [--editor s]")
  exit(2)
}
func option(_ name: String) -> Double? {
  guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
  return Double(arguments[at + 1])
}
let presetLimit = Int(option("--presets") ?? 1000)
let editorSeconds = option("--editor") ?? 1

let description = AudioComponentDescription(
  componentType: fourCC(arguments[1]), componentSubType: fourCC(arguments[2]),
  componentManufacturer: fourCC(arguments[3]), componentFlags: 0, componentFlagsMask: 0)

NSApplication.shared.setActivationPolicy(.accessory)

// .............................................................................
// Find and load

var components: [AVAudioUnitComponent] = []
wait(15) {
  components = AVAudioUnitComponentManager.shared().components(matching: description)
  return !components.isEmpty
}
report("find", !components.isEmpty, ["names": components.map { $0.name }])
if components.isEmpty { exit(1) }

func load() -> (AVAudioUnit?, Double) {
  var unit: AVAudioUnit?
  var done = false
  let start = Date()
  AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess) { au, error in
    unit = au
    done = true
    if let error { print("load error: \(error)") }
  }
  wait(15) { done }
  return (unit, Date().timeIntervalSince(start) * 1000)
}

let (loaded, loadMs) = load()
report("load", loaded != nil, ["ms": loadMs])
guard let unit = loaded else { exit(1) }
let au = unit.auAudioUnit

// .............................................................................
// Parameters and presets

let tree = au.parameterTree
let parameters = tree?.allParameters ?? []
let presetParameter = parameters.first { $0.identifier == "preset" }
let factory = au.factoryPresets ?? []
report("presets",
       !factory.isEmpty && presetParameter != nil
         && presetParameter?.valueStrings?.count == factory.count,
       ["factory": factory.map { $0.name },
        "parameters": parameters.map { $0.identifier }])

// .............................................................................
// Offline rendering

final class Renderer {
  let engine = AVAudioEngine()
  let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  let buffer: AVAudioPCMBuffer

  let units: [AVAudioUnit]

  init(_ units: [AVAudioUnit], frames: AVAudioFrameCount) throws {
    self.units = units
    for unit in units {
      engine.attach(unit)
      engine.connect(unit, to: engine.mainMixerNode, format: format)
    }
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
    try engine.start()
    buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
  }

  // Stops the engine and gives the units free for another one.
  func close() {
    engine.stop()
    for unit in units { engine.detach(unit) }
  }

  // Renders `blocks` blocks and returns the peak of the left channel.
  func render(_ blocks: Int, frames: AVAudioFrameCount) throws -> Float {
    var peak: Float = 0
    for _ in 0..<blocks {
      _ = try engine.renderOffline(frames, to: buffer)
      let left = buffer.floatChannelData![0]
      for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(left[i])) }
    }
    return peak
  }
}

func notes(_ au: AUAudioUnit, on: Bool) {
  guard let send = au.scheduleMIDIEventBlock else { return }
  for channel: UInt8 in 0..<4 {
    send(AUEventSampleTimeImmediate, 0, 3, [(on ? 0x90 : 0x80) | channel, 60, on ? 100 : 0])
  }
}

do {
  let renderer = try Renderer([unit], frames: 512)
  au.isRenderingOffline = true
  for (index, preset) in factory.prefix(presetLimit).enumerated() {
    au.currentPreset = preset
    wait(5) { Int(presetParameter?.value ?? -1) == index }
    notes(au, on: true)
    let peak = try renderer.render(94, frames: 512)  // 1 s
    notes(au, on: false)
    let tail = try renderer.render(94, frames: 512)
    report("preset", peak > 0.001 && peak <= 1.0,
           ["index": index, "name": preset.name, "peak": peak, "afterNoteOff": tail,
            "presetParameter": presetParameter?.value ?? -1])
  }

  // State: a preset, a parameter and a control, saved and restored.
  let graphParameter = parameters.first {
    $0.identifier != "preset" && !$0.identifier.hasPrefix("control_")
  }
  let control = parameters.first { $0.identifier.hasPrefix("control_") }
  let presetIndex = factory.count > 1 ? 1 : 0
  au.currentPreset = factory[presetIndex]
  wait(5) { Int(presetParameter?.value ?? -1) == presetIndex }
  let graphValue = graphParameter.map { $0.minValue + ($0.maxValue - $0.minValue) * 0.37 } ?? 0
  graphParameter?.value = graphValue
  control?.value = 0.8
  // A host's changes reach a unit out of process on a path of their own;
  // a host saves its project long after them.
  wait(1) { false }
  let state = au.fullState ?? [:]
  au.currentPreset = factory[0]
  graphParameter?.value = graphParameter?.minValue ?? 0
  control?.value = 0.1
  wait(1) { false }
  au.fullState = state
  wait(5) { Int(presetParameter?.value ?? -1) == presetIndex }
  let restoredGraph = graphParameter?.value ?? 0
  let restoredControl = control?.value ?? 0
  report("state",
         Int(presetParameter?.value ?? -1) == presetIndex
           && abs(restoredGraph - graphValue) <= max(0.001, abs(graphValue) * 0.001)
           && abs(restoredControl - 0.8) < 0.001
           && state["aud_state"] is String,
         ["preset": presetParameter?.value ?? -1, "graph": restoredGraph,
          "expectedGraph": graphValue, "control": restoredControl,
          "currentPreset": au.currentPreset?.name ?? ""])

  // Realtime: blocks of 128 frames timed.
  renderer.close()
  au.isRenderingOffline = false
  let realtime = try Renderer([unit], frames: 128)
  var worstMs = 0.0
  var totalMs = 0.0
  notes(au, on: true)
  for _ in 0..<375 {  // 1 s
    let start = DispatchTime.now().uptimeNanoseconds
    _ = try realtime.render(1, frames: 128)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    worstMs = max(worstMs, ms)
    totalMs += ms
  }
  notes(au, on: false)
  realtime.close()
  report("realtime", worstMs < 2.67, ["meanMs": totalMs / 375, "maxMs": worstMs,
                                      "budgetMs": 128.0 / 48.0])
} catch {
  report("render", false, ["error": "\(error)"])
}

// .............................................................................
// Two instances

let (second, _) = load()
if let second {
  do {
    let renderer = try Renderer([second], frames: 512)
    notes(second.auAudioUnit, on: true)
    let peak = try renderer.render(94, frames: 512)
    report("twoInstances", peak > 0.001, ["peak": peak])
  } catch {
    report("twoInstances", false, ["error": "\(error)"])
  }
} else {
  report("twoInstances", false)
}

// .............................................................................
// Editor

var controller: NSViewController?
var asked = false
au.requestViewController { vc in
  controller = vc
  asked = true
}
wait(10) { asked }
if let controller {
  let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 400),
                        styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.orderFrontRegardless()
  wait(editorSeconds) { false }
  report("editor", true, ["size": "\(controller.preferredContentSize)"])
  window.close()
} else {
  report("editor", false)
}

exit(failed ? 1 : 0)
