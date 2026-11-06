// Cannon targeting and the one-hit-per-swing gate, ported from targeting.js.
import Foundation

public func circleEntry(_ a: Point, _ b: Point, _ c: Point, _ r: Double) -> Double {
  let dx = b.x - a.x, dy = b.y - a.y, ox = a.x - c.x, oy = a.y - c.y, q = dx * dx + dy * dy, v = ox * ox + oy * oy - r * r
  if v <= 0 { return 0 }
  if q == 0 { return .infinity }
  let p = ox * dx + oy * dy, d = p * p - q * v
  if d < 0 { return .infinity }
  let t = (-p - d.squareRoot()) / q
  return t >= 0 && t <= 1 ? t : .infinity
}

public func boxEntry(_ a: Point, _ b: Point, _ box: Box, pad: Double = 0) -> Double {
  var lo = 0.0, hi = 1.0
  let dx = b.x - a.x, dy = b.y - a.y
  let sides: [(Double, Double)] = [(-dx, a.x - box.x + pad), (dx, box.x + box.w + pad - a.x), (-dy, a.y - box.y + pad), (dy, box.y + box.h + pad - a.y)]
  for (p, q) in sides {
    if p == 0 { if q < 0 { return .infinity } } else {
      let t = q / p
      if p < 0 { lo = max(lo, t) } else { hi = min(hi, t) }
      if lo > hi { return .infinity }
    }
  }
  return lo
}

public protocol Target: AnyObject {
  var x: Double { get }
  var y: Double { get }
  var r: Double { get }
  var box: Box? { get }
}

/// The nearest character or prompt box the shot's path entered this frame.
public func projectileTarget<T: Target>(from: Point, to: Point, _ entities: [T]) -> T? {
  var target: T? = nil, nearest = Double.infinity
  for e in entities {
    var entry = circleEntry(from, to, Point(e.x, e.y), e.r + 24)
    if let b = e.box { entry = min(entry, boxEntry(from, to, b, pad: 12)) }
    if entry != .infinity && entry <= nearest { nearest = entry; target = e }
  }
  return target
}

/// A swing answers one prompt; it re-arms after the hand pauses or reverses direction.
public struct SwingGate {
  public var spent = false
  var quiet = 0
  public var last = Point(850, 450)
  var direction: Point? = nil
  var lastHit = Int.min / 2
  public init() {}
  public mutating func reset() { spent = false; direction = nil }
  public mutating func move(_ mouse: Point, tick: Int) {
    let dx = mouse.x - last.x, dy = mouse.y - last.y, speed = hypot(dx, dy)
    last = mouse
    if speed <= 4 { quiet += 1; return }
    let dir = Point(dx / speed, dy / speed)
    if quiet >= 12 || speed > 8 && direction.map({ dir.x * $0.x + dir.y * $0.y < -0.4 }) == true && tick - lastHit > 12 { spent = false }
    direction = dir; quiet = 0
  }
  public mutating func consume(tick: Int) { spent = true; lastHit = tick }
}
