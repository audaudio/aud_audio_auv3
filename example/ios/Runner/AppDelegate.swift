// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import AVFoundation
import CoreAudioKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var host: AudSpikeHost?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AudSpikeHost") else {
      return
    }
    let host = AudSpikeHost(messenger: registrar.messenger())
    self.host = host
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      host.start(arguments: ProcessInfo.processInfo.arguments)
    }
  }
}

// The host of the spike's Audio Unit (ticket 24): loads instances of the
// unit out of process into an AVAudioEngine, opens their editors and
// reports the extension's footprint, the editors' first frames and whether
// the units still render, once a second, as JSON lines on stderr (which
// `xcrun devicectl device process launch --console` shows) and on the
// screen. The speaker stays silent; the units render all the same.
//
//   --instances n   units to load (1)
//   --duration s    seconds with the editors open (60)
//   --editors 0     no editors, the footprint without Flutter
final class AudSpikeHost {
  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private var units: [AVAudioUnit] = []
  private var controllers: [UIViewController] = []
  private var peaks: [Float] = []
  private let peakLock = NSLock()
  private var started = Date()
  private var container: UIScrollView?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "aud_auv3/host", binaryMessenger: messenger)
  }

  func start(arguments: [String]) {
    let instances = Int(AudSpikeHost.value(of: "--instances", in: arguments) ?? "") ?? 1
    let duration = Double(AudSpikeHost.value(of: "--duration", in: arguments) ?? "") ?? 60
    let editors = AudSpikeHost.value(of: "--editors", in: arguments) != "0"
    UIApplication.shared.isIdleTimerDisabled = true
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      report(["kind": "error", "message": "session: \(error)"])
    }
    started = Date()
    report(["kind": "start", "instances": instances, "duration": duration, "editors": editors])
    waitForComponent(attempts: 30) {
      self.run(instances: instances, duration: duration, editors: editors)
    }
  }

  // The system registers the extension of a fresh install asynchronously.
  private func waitForComponent(attempts: Int, then: @escaping () -> Void) {
    let found = AVAudioUnitComponentManager.shared().components(matching: AudSpikeHost.description)
    if !found.isEmpty || attempts <= 0 {
      let music = AudioComponentDescription(
        componentType: AudSpikeHost.fourCC("aumu"), componentSubType: 0, componentManufacturer: 0,
        componentFlags: 0, componentFlagsMask: 0)
      report([
        "kind": "components",
        "music": AVAudioUnitComponentManager.shared().components(matching: music).map {
          "\($0.manufacturerName): \($0.name)"
        },
      ])
      then()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      self.waitForComponent(attempts: attempts - 1, then: then)
    }
  }

  private func run(instances: Int, duration: Double, editors: Bool) {
    load(count: instances) {
      self.sample("loaded")
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        self.sample("closed")
        if editors { self.openEditors() }
        self.every(second: 1, until: duration) {
          self.sample(editors ? "open" : "closed")
        } done: {
          self.report(["kind": "done"])
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
      }
    }
  }

  private static let description = AudioComponentDescription(
    componentType: fourCC("aumu"),
    componentSubType: fourCC("AudS"),
    componentManufacturer: fourCC("Audn"),
    componentFlags: 0, componentFlagsMask: 0)

  private func load(count: Int, then: @escaping () -> Void) {
    let description = AudSpikeHost.description
    var remaining = count
    for index in 0..<count {
      AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess]) { unit, error in
        DispatchQueue.main.async {
          guard let unit = unit else {
            self.report(["kind": "error", "message": "instantiate: \(String(describing: error))"])
            return
          }
          self.engine.attach(unit)
          self.engine.connect(unit, to: self.engine.mainMixerNode, format: nil)
          self.peakLock.lock()
          self.peaks.append(0)
          self.peakLock.unlock()
          let slot = self.units.count
          self.units.append(unit)
          unit.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            var peak: Float = 0
            if let data = buffer.floatChannelData {
              for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(data[0][frame]))
              }
            }
            self.peakLock.lock()
            self.peaks[slot] = max(self.peaks[slot], peak)
            self.peakLock.unlock()
          }
          self.report(["kind": "loaded", "index": index])
          remaining -= 1
          if remaining == 0 {
            self.engine.mainMixerNode.outputVolume = 0
            do {
              try self.engine.start()
            } catch {
              self.report(["kind": "error", "message": "engine: \(error)"])
            }
            then()
          }
        }
      }
    }
  }

  private func openEditors() {
    guard
      let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first?.windows.first,
      let root = window.rootViewController
    else {
      report(["kind": "error", "message": "no window"])
      return
    }
    let scroll = UIScrollView(
      frame: CGRect(
        x: 0, y: 140, width: root.view.bounds.width, height: root.view.bounds.height - 140))
    scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    root.view.addSubview(scroll)
    container = scroll
    for (index, unit) in units.enumerated() {
      unit.auAudioUnit.requestViewController { controller in
        DispatchQueue.main.async {
          guard let controller = controller else {
            self.report(["kind": "error", "message": "no view controller \(index)"])
            return
          }
          root.addChild(controller)
          let width: CGFloat = 620
          let height: CGFloat = 220
          let columns = max(1, Int(scroll.bounds.width / (width + 16)))
          controller.view.frame = CGRect(
            x: 16 + CGFloat(index % columns) * (width + 16),
            y: 16 + CGFloat(index / columns) * (height + 16), width: width, height: height)
          scroll.addSubview(controller.view)
          controller.didMove(toParent: root)
          scroll.contentSize = CGSize(
            width: scroll.bounds.width,
            height: max(scroll.contentSize.height, controller.view.frame.maxY + 16))
          self.controllers.append(controller)
          self.report(["kind": "editor", "index": index])
        }
      }
    }
  }

  private func sample(_ label: String) {
    let footprint = units.first?.auAudioUnit.parameterTree?
      .parameter(withAddress: AudSpikeHost.footprintAddress)?.value ?? -1
    let firstFrames = units.map {
      $0.auAudioUnit.parameterTree?.parameter(withAddress: AudSpikeHost.firstFrameAddress)?
        .value ?? -1
    }
    peakLock.lock()
    let rendering = peaks.map { $0 > 0 }
    for index in peaks.indices { peaks[index] = 0 }
    peakLock.unlock()
    report([
      "kind": "sample", "label": label, "footprintMb": footprint, "firstFrameMs": firstFrames,
      "rendering": rendering, "instances": units.count, "editors": controllers.count,
    ])
  }

  private func every(
    second interval: Double, until duration: Double, _ tick: @escaping () -> Void,
    done: @escaping () -> Void
  ) {
    let end = Date().addingTimeInterval(duration)
    Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
      tick()
      if Date() >= end {
        timer.invalidate()
        done()
      }
    }
  }

  private func report(_ fields: [String: Any]) {
    var record = fields
    record["t"] = Date().timeIntervalSince(started)
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
      let line = String(data: data, encoding: .utf8)
    else { return }
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    channel.invokeMethod("status", arguments: line)
  }

  // The stable id of a parameter, as aud_host_param_id computes it.
  private static func stableId(_ text: String) -> AUParameterAddress {
    var hash: UInt32 = 0x811c_9dc5
    for byte in text.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 0x0100_0193
    }
    return AUParameterAddress(hash & 0x7fff_ffff)
  }

  private static let footprintAddress = stableId("spike/footprint")
  private static let firstFrameAddress = stableId("spike/firstFrame")

  private static func fourCC(_ code: String) -> OSType {
    return code.utf8.reduce(0) { ($0 << 8) | OSType($1) }
  }

  private static func value(of option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}
