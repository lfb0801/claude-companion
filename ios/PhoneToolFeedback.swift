import AVFoundation
import CoreHaptics
import Foundation
import OSLog
import UIKit

enum PhoneTool {
  case whip, stamp

  /// Ratio of the measured motion to the threshold for this tool.
  func progress(rotation: Double, force: Double) -> Double {
    switch self {
    case .whip: min(rotation / 4.5, force / 0.9)
    case .stamp: force / 1.65
    }
  }
}

struct PhoneToolMotion {
  enum Update: Equatable { case ramp(Float), actuate }

  static let armedIntensity: Float = 0.32

  private var ready = false
  private var hasActuated = false

  mutating func sample(_ tool: PhoneTool, rotation: Double, force: Double, enabled: Bool) -> Update {
    let settled = rotation < 1.8 && force < 0.35
    if settled { ready = true }
    guard enabled else { return .ramp(0) }
    guard ready else { return .ramp(hasActuated ? 0 : Self.armedIntensity) }
    let progress = tool.progress(rotation: rotation, force: force)
    if progress >= 1 {
      ready = false
      hasActuated = true
      return .actuate
    }
    if hasActuated && settled { return .ramp(0) }
    return .ramp(Self.armedIntensity + 0.56 * Float(progress))
  }
}

@MainActor
final class PhoneToolFeedback {
  private let logger = Logger(subsystem: Bundle.companionID + ".phone-whip", category: "Haptics")
  private var engine: CHHapticEngine?
  private var player: CHHapticAdvancedPatternPlayer?
  private let impact = UIImpactFeedbackGenerator(style: .rigid)
  private var lastImpact: TimeInterval?
  private var audio: AVAudioPlayer?

  func ramp(_ level: Float) {
    guard level > 0 else { stop(); return }
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    if lastImpact != nil {
      pulse(level)
      return
    }
    do {
      if player == nil {
        let engine = try engine ?? CHHapticEngine(audioSession: nil)
        self.engine = engine
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        engine.resetHandler = { [weak self] in
          Task { @MainActor in self?.player = nil }
        }
        try engine.start()
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.38),
        ], relativeTime: 0, duration: 1)
        let pattern = try CHHapticPattern(events: [event], parameters: [intensity(level)])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.loopEnd = pattern.duration
        player.loopEnabled = true
        try player.start(atTime: CHHapticTimeImmediate)
        self.player = player
      } else {
        try player?.sendParameters([intensity(level)], atTime: CHHapticTimeImmediate)
      }
    } catch {
      logger.error("Continuous haptics failed: \(error.localizedDescription, privacy: .public)")
      stop()
      engine = nil
      pulse(level)
    }
  }

  private func pulse(_ level: Float) {
    let now = ProcessInfo.processInfo.systemUptime
    if let lastImpact, now - lastImpact < 0.12 { return }
    lastImpact = now
    impact.impactOccurred(intensity: CGFloat(level))
  }

  private func intensity(_ value: Float) -> CHHapticDynamicParameter {
    CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)
  }

  func stop() {
    try? player?.stop(atTime: CHHapticTimeImmediate)
    player = nil
    lastImpact = nil
  }

  func sound(_ tool: PhoneTool) {
    // Use the device's regular Silent setting and mix with other audio.
    let session = AVAudioSession.sharedInstance()
    guard UIApplication.shared.applicationState == .active, session.category != .record else { return }
    try? session.setCategory(.ambient)
    audio = try? AVAudioPlayer(data: tool == .whip ? Self.crack : Self.thump)
    audio?.play()
  }

  private static let crack = wave(.whip)
  private static let thump = wave(.stamp)

  private static func wave(_ tool: PhoneTool) -> Data {
    let rate: UInt32 = 22_050
    let samples = Int(Double(rate) * 0.17)
    var bytes = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }
    bytes.append(Data("RIFF".utf8)); append(UInt32(36 + samples * 2))
    bytes.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
    bytes.append(Data("data".utf8)); append(UInt32(samples * 2))
    var seed: UInt32 = 12
    var filtered = 0.0
    for index in 0..<samples {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      let noise = Double(seed) / Double(UInt32.max) * 2 - 1
      let t = Double(index) / Double(rate)
      filtered += (noise - filtered) * 0.16
      let sample: Double
      switch tool {
      case .whip:
        sample = 0.85 * noise * exp(-t * 160) + 0.56 * filtered * exp(-t * 43)
          + 0.35 * sin(2 * .pi * (270 * t - 550 * t * t)) * exp(-t * 35)
      case .stamp:
        sample = 0.68 * sin(2 * .pi * (146 * t - 245 * t * t)) * exp(-t * 35)
          + 0.62 * filtered * exp(-t * 58) + 0.25 * noise * exp(-t * 205)
      }
      append(Int16(tanh(sample * 1.45) * Double(Int16.max)))
    }
    return bytes
  }
}
