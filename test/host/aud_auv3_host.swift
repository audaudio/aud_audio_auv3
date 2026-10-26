// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The test host of the AUv3 shell (ticket 64), as Logic Pro loads a unit:
// it finds the component, loads it out of process and checks the preset
// parameter and the factory presets, every preset sounding offline with a
// note on each of the MIDI channels 1 to 4, the state round trip with a
// moved control, two instances side by side, the time of realtime blocks
// and the editor's view. One JSON line per check on stdout; the exit code
// is 1 when one fails.
//
//   aud_auv3_host <type> <subtype> <manufacturer> [--presets n]
//     [--editor seconds] [--snapshot <png>] [--tap x,y] [--play seconds]
//
// --play renders blocks of 128 frames at the pace of the clock, as a host
// plays live, with a new note every 120 ms over five octaves, and counts
// the gaps: runs of 64 or more silent frames while notes sound.
//
// --tap clicks into the open editor at the fractions x and y of its width
// and height (from the top) and renders a second without notes of the
// host: what sounds came from the editor. The click is a system event:
// the editor's remote view ignores events a host makes for its own
// window. It needs the Accessibility permission of the app responsible
// for the process that starts the host, and takes a snapshot while the
// button is down when --snapshot is given.

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
// A PNG of the editor's window, taken after editorSeconds.
let snapshot: String? = arguments.firstIndex(of: "--snapshot").flatMap {
  $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
}
let tap: (Double, Double)? = arguments.firstIndex(of: "--tap").flatMap { at in
  guard at + 1 < arguments.count else { return nil }
  let parts = arguments[at + 1].split(separator: ",").compactMap { Double($0) }
  return parts.count == 2 ? (parts[0], parts[1]) : nil
}
let playSeconds = option("--play")

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

// The MIDI output a host offers as a MIDI source; the host's block takes
// what the unit sends - the editor's notes, none here.
report("midiOutput", au.midiOutputNames == ["MIDI Out"], ["names": au.midiOutputNames])
au.midiOutputEventBlock = { _, _, _, _ in noErr }

// .............................................................................
// Offline rendering

final class Renderer {
  let engine = AVAudioEngine()
  let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  let buffer: AVAudioPCMBuffer

  let units: [AVAudioUnit]

  // The engine sets its units to render offline in the mode .offline, so
  // that a unit's streams wait for the disk; .realtime keeps them live.
  init(_ units: [AVAudioUnit], frames: AVAudioFrameCount,
       mode: AVAudioEngineManualRenderingMode = .offline) throws {
    self.units = units
    for unit in units {
      engine.attach(unit)
      engine.connect(unit, to: engine.mainMixerNode, format: format)
    }
    try engine.enableManualRenderingMode(mode, format: format, maximumFrameCount: frames)
    try engine.start()
    buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
  }

  // Renders a block in the mode .realtime.
  func renderLive(_ frames: AVAudioFrameCount) -> Bool {
    var status = noErr
    buffer.frameLength = frames
    return engine.manualRenderingBlock(frames, buffer.mutableAudioBufferList, &status) == .success
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

  // Live play: blocks at the pace of the clock, a note every 120 ms, on an
  // instance of its own - one out of process may keep rendering offline
  // after the host turned it off.
  if let playSeconds, let player = load().0, let send = player.auAudioUnit.scheduleMIDIEventBlock {
    let live = try Renderer([player], frames: 128, mode: .realtime)
    let blockNs = UInt64(128.0 / 48000.0 * 1e9)
    let blocks = Int(playSeconds * 48000 / 128)
    let noteBlocks = 45  // 120 ms
    var playing: [UInt8] = []
    var gaps = 0
    var silentRun = 0
    var peak: Float = 0
    var failedBlocks = 0
    var next = DispatchTime.now().uptimeNanoseconds
    for b in 0..<blocks {
      if b % noteBlocks == 0 {
        // Each note sounds for four notes' time.
        if playing.count >= 4 { send(AUEventSampleTimeImmediate, 0, 3, [0x80, playing.removeFirst(), 0]) }
        let note = UInt8(36 + (b / noteBlocks * 7) % 60)
        send(AUEventSampleTimeImmediate, 0, 3, [0x90, note, 100])
        playing.append(note)
      }
      if !live.renderLive(128) { failedBlocks += 1 }
      let left = live.buffer.floatChannelData![0]
      for i in 0..<Int(live.buffer.frameLength) {
        let value = abs(left[i])
        peak = max(peak, value)
        if value == 0 {
          silentRun += 1
          if silentRun == 64 && b > noteBlocks { gaps += 1 }
        } else {
          silentRun = 0
        }
      }
      next += blockNs
      let now = DispatchTime.now().uptimeNanoseconds
      if next > now { usleep(useconds_t((next - now) / 1000)) }
    }
    for note in playing { send(AUEventSampleTimeImmediate, 0, 3, [0x80, note, 0]) }
    live.close()
    report("play", gaps == 0 && failedBlocks == 0 && peak > 0.001,
           ["seconds": playSeconds, "gaps": gaps, "failedBlocks": failedBlocks, "peak": peak])
  }
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
    notes(second.auAudioUnit, on: false)
    renderer.close()
    report("twoInstances", peak > 0.001, ["peak": peak])
  } catch {
    report("twoInstances", false, ["error": "\(error)"])
  }
} else {
  report("twoInstances", false)
}

// A project restored keeps an untouched control untouched: the base class
// sets every parameter of the tree again, which must not move it.
if let second {
  let controlsOf = { (state: [String: Any]?) -> [String: Any] in
    guard let text = state?["aud_state"] as? String,
          let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { return ["missing": true] }
    return json["controls"] as? [String: Any] ?? [:]
  }
  let saved = second.auAudioUnit.fullState
  let before = controlsOf(saved)
  second.auAudioUnit.fullState = saved
  wait(1) { false }
  let after = controlsOf(second.auAudioUnit.fullState)
  report("untouchedControl", before.isEmpty && after.isEmpty,
         ["before": before.count, "after": after.count])
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
  var fields: [String: Any] = ["size": "\(controller.preferredContentSize)"]
  var editorOk = true
  if let tap, let renderer = try? Renderer([unit], frames: 512) {
    _ = try? renderer.render(94, frames: 512)  // the host's notes fade
    let silence = (try? renderer.render(20, frames: 512)) ?? -1
    // Quartz counts from the top of the main screen.
    let frame = window.contentLayoutRect
    let origin = window.convertToScreen(frame).origin
    let height = NSScreen.screens.first?.frame.height ?? 0
    let point = CGPoint(
      x: origin.x + frame.width * tap.0,
      y: height - (origin.y + frame.height * (1 - tap.1)))
    let source = CGEventSource(stateID: .hidSystemState)
    func click(_ type: CGEventType) {
      CGEvent(mouseEventSource: source, mouseType: type,
              mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    click(.leftMouseDown)
    wait(0.3) { false }
    if let snapshot {
      let pressed = Process()
      pressed.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      pressed.arguments = ["-x", "-o", "-l", "\(window.windowNumber)",
                           snapshot.replacingOccurrences(of: ".png", with: "-pressed.png")]
      try? pressed.run()
      pressed.waitUntilExit()
    }
    let peak = (try? renderer.render(94, frames: 512)) ?? -1
    click(.leftMouseUp)
    renderer.close()
    fields["tapPeak"] = peak
    fields["silenceBefore"] = silence
    editorOk = peak > 0.001 && peak > silence * 2
  }
  if let snapshot {
    // The window shows another process's view: only the window server
    // has its pixels.
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", snapshot]
    try? capture.run()
    capture.waitUntilExit()
    fields["snapshot"] = snapshot
  }
  report("editor", editorOk, fields)
  window.close()
} else {
  report("editor", false)
}

exit(failed ? 1 : 0)
