// Stage sounds: the two clips (whip summon, cannon cue) and synthesized effects ported from theater.js.
import AVFoundation
import StageCore

final class Audio {
  var muted = false
  private let engine = AVAudioEngine()
  private var players: [AVAudioPlayerNode] = []
  private var next = 0
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
  private var lastPlayed: [String: CFTimeInterval] = [:]
  private let gaps: [String: Double] = ["crack": 0.05, "approve": 0.08, "fire": 0.04, "ping": 0.09, "whoosh": 0.3, "warn": 0.35, "toggle": 0.15, "thunk": 0.3, "tally": 0.25]
  private var whipCue: AVAudioPlayer?
  private var cannonCue: AVAudioPlayer?

  init() {
    for _ in 0..<8 { let p = AVAudioPlayerNode(); engine.attach(p); engine.connect(p, to: engine.mainMixerNode, format: format); players.append(p) }
    try? engine.start()
    whipCue = clip("whip-summon"); cannonCue = clip("little-friend")
  }

  private func clip(_ name: String) -> AVAudioPlayer? {
    guard let url = resource(name, "mp3") else { return nil }
    let p = try? AVAudioPlayer(contentsOf: url); p?.volume = 0.8; p?.prepareToPlay(); return p
  }

  func play(_ s: Sound) {
    switch s {
    case .stopCues: for c in [whipCue, cannonCue] { c?.stop(); c?.currentTime = 0 }; return
    case .whipCue: restart(whipCue); return
    case .cannonCue: restart(cannonCue); return
    default: break
    }
    guard !muted else { return }
    let key = name(s), now = CACurrentMediaTime()
    if now - (lastPlayed[key] ?? -9) < (gaps[key] ?? 0) { return }
    lastPlayed[key] = now
    schedule(render(s))
  }

  private func restart(_ c: AVAudioPlayer?) { guard !muted, let c else { return }; c.currentTime = 0; c.play() }

  private func name(_ s: Sound) -> String {
    switch s { case .ping: "ping"; case .warn: "warn"; case .whoosh: "whoosh"; case .thunk: "thunk"; case .toggle: "toggle"; case .tally: "tally"; case .crack: "crack"; case .approve: "approve"; case .fire: "fire"; default: "cue" }
  }

  private func schedule(_ samples: [Float]) {
    guard !samples.isEmpty, engine.isRunning, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
    let p = players[next]; next = (next + 1) % players.count
    p.scheduleBuffer(buf, at: nil, options: .interrupts)
    if !p.isPlaying { p.play() }
  }

  // MARK: synthesis

  private let rate = 44100.0
  private struct Mix {
    var out: [Float]
    let rate: Double
    init(seconds: Double, rate: Double) { out = .init(repeating: 0, count: Int(seconds * rate)); self.rate = rate }
    /// An oscillator sweeping f0→f1 with an exponential fade, like WebAudio's exponentialRampToValueAtTime.
    mutating func osc(_ wave: String, _ f0: Double, _ f1: Double, _ dur: Double, _ vol: Double, at: Double = 0) {
      var phase = 0.0
      let start = Int(at * rate), n = Int(dur * rate)
      for i in 0..<n where start + i < out.count {
        let t = Double(i) / Double(n), f = f0 * pow(f1 / f0, t), g = vol * pow(0.001 / vol, t)
        phase += f / rate
        let x = phase - floor(phase)
        let v: Double
        switch wave {
        case "square": v = x < 0.5 ? 1 : -1
        case "triangle": v = 4 * abs(x - 0.5) - 1
        case "sawtooth": v = 2 * x - 1
        default: v = sin(2 * .pi * x)
        }
        out[start + i] += Float(v * g)
      }
    }
    /// Filtered noise with a shaped envelope (cracks, thunks, whooshes).
    mutating func noise(_ dur: Double, at: Double = 0, smooth: Double, env: (Double) -> Double) {
      var y = 0.0
      let start = Int(at * rate), n = Int(dur * rate)
      for i in 0..<n where start + i < out.count {
        let t = Double(i) / Double(n)
        y += (Double.random(in: -1...1) - y) * smooth
        out[start + i] += Float(y * env(t))
      }
    }
  }

  private func render(_ s: Sound) -> [Float] {
    var m = Mix(seconds: 1.4, rate: rate)
    switch s {
    case .ping(let n): let f = 440 * pow(2, Double(min(max(n, 0), 24)) / 12); m.osc("sine", f, f * 1.5, 0.22, 0.08); m.osc("sine", f * 2, f * 3, 0.12, 0.03, at: 0.03)
    case .warn: m.osc("square", 430, 390, 0.09, 0.045); m.osc("square", 430, 390, 0.09, 0.045, at: 0.13)
    case .thunk(let light):
      let q = light ? 0.55 : 1
      m.osc("sine", light ? 110 : 150, light ? 50 : 42, light ? 0.16 : 0.24, 0.34 * q); m.osc("triangle", light ? 200 : 320, light ? 90 : 70, 0.1, 0.09 * q)
      if !light { m.noise(0.2, smooth: 0.35) { 0.2 * (1 - $0) * pow(0.005, $0) } }
    case .tally: for i in 0..<5 { m.osc("square", 1700 + Double(i) * 90, 1701 + Double(i) * 90, 0.025, 0.035, at: Double(i) * 0.035) }; m.osc("sine", 1400, 2100, 0.12, 0.05, at: 0.2)
    case .toggle(let on): on ? m.osc("sine", 500, 800, 0.14, 0.07) : m.osc("sine", 600, 300, 0.18, 0.07)
    case .whoosh: m.noise(0.5, smooth: 0.25) { t in 0.13 * (t < 0.3 ? t / 0.3 : pow(0.001, (t - 0.3) / 0.7)) }
    case .crack: m.noise(0.12, smooth: 1) { 0.15 * (1 - $0) * pow(0.01, $0) }
    case .approve: m.osc("sine", 720, 1100, 0.16, 0.07)
    case .fire: m.osc("square", 170, 70, 0.16, 0.07)
    default: return []
    }
    if let last = m.out.lastIndex(where: { abs($0) > 0.0005 }) { m.out.removeSubrange((last + 1)...) }
    return m.out
  }
}
