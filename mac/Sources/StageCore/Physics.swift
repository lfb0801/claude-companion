// Whip rope physics and collision, ported from physics.js (OpenWhip-style verlet rope).
import Foundation

@inline(__always) func clamp(_ n: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, n)) }

public struct Point: Equatable, Sendable {
  public var x: Double, y: Double
  public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct RopePoint: Sendable {
  public var x: Double, y: Double, px: Double, py: Double
  public init(x: Double, y: Double, px: Double, py: Double) { self.x = x; self.y = y; self.px = px; self.py = py }
  var p: Point { Point(x, y) }
  var prev: Point { Point(px, py) }
}

public struct Box: Equatable, Sendable {
  public var x: Double, y: Double, w: Double, h: Double
  public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
  public func contains(_ p: Point) -> Bool { p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + h }
}

public final class Whip {
  public static let count = 28
  public var points: [RopePoint]
  var anchor: Point, old: Point
  var angle = -0.85, age = 0, lastCrack = -100, lastGesture = -100, flick = 0

  public init(_ x: Double = 800, _ y: Double = 400, width: Double = 1600, height: Double = 900) {
    points = (0..<Whip.count).map { i in RopePoint(x: x + Double(i) * 3, y: y + Double(i) * 17, px: x + Double(i) * 3, py: y + Double(i) * 17) }
    anchor = Point(x, y); old = Point(x, y)
    for _ in 0..<180 { _ = step(Point(x, y), width: width, height: height) }
    age = 0; lastGesture = -100
  }

  func length(_ i: Int) -> Double { 22 * (1 - Double(i) / 27 * 0.4) }
  public func kick() { flick = 18 }

  /// Advances one frame towards the hand position. Returns true when the tip cracks.
  @discardableResult
  public func step(_ mouse: Point, width: Double, height: Double) -> Bool {
    age += 1
    var mx = clamp(mouse.x, 0, width), my = clamp(mouse.y, 0, height)
    let inputSpeed = hypot(mx - old.x, my - old.y)
    if inputSpeed > 15 || flick > 0 { lastGesture = age }
    let target = -0.85 + clamp((mx - old.x) * 0.002 + (my - old.y) * 0.001, -0.25, 0.25)
    angle += (target - angle) * 0.12
    old = Point(mx, my)
    if flick > 0 {
      let phase = Double(18 - flick) / 17
      mx += sin(phase * .pi * 2) * 155; my -= sin(phase * .pi) * 45; flick -= 1
    }
    let start = anchor
    anchor.x += (clamp(mx, 0, width) - anchor.x) * 0.55
    anchor.y += (clamp(my, 0, height) - anchor.y) * 0.55
    for sub in 1...3 {
      let hx = start.x + (anchor.x - start.x) * Double(sub) / 3, hy = start.y + (anchor.y - start.y) * Double(sub) / 3
      for i in 2..<Whip.count {
        var p = points[i]
        let vx = (p.x - p.px) * 0.97, vy = (p.y - p.py) * 0.97
        p.px = p.x; p.py = p.y; p.x += vx; p.y += vy + 1.2 / 9
        points[i] = p
      }
      points[0] = RopePoint(x: hx, y: hy, px: hx, py: hy)
      let hxx = hx + cos(angle) * length(0), hyy = hy + sin(angle) * length(0)
      points[1] = RopePoint(x: hxx, y: hyy, px: hxx, py: hyy)
      for _ in 0..<16 {
        for i in 1..<(Whip.count - 1) {
          var a = points[i], b = points[i + 1]
          let dx = b.x - a.x, dy = b.y - a.y, d = hypot(dx, dy) == 0 ? 0.0001 : hypot(dx, dy), f = (d - length(i)) / d
          if i > 1 { a.x += dx * f * 0.5; a.y += dy * f * 0.5; b.x -= dx * f * 0.5; b.y -= dy * f * 0.5 } else { b.x -= dx * f; b.y -= dy * f }
          points[i] = a; points[i + 1] = b
        }
        for i in 1..<Whip.count {
          var p = points[i]
          let x = clamp(p.x, 0, width), y = clamp(p.y, 0, height)
          if x != p.x { p.x = x; p.px = x }
          if y != p.y { p.y = y; p.py = y }
          points[i] = p
        }
      }
    }
    let tip = points[Whip.count - 1], speed = hypot(tip.x - tip.px, tip.y - tip.py) * 3
    if (speed > 125 && age > 21 || flick > 0 && speed > 20) && age - lastGesture < 24 && age - lastCrack > 18 { lastCrack = age; return true }
    return false
  }
}

public func segmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
  let dx = b.x - a.x, dy = b.y - a.y, q = dx * dx + dy * dy
  let t = clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / (q == 0 ? 1 : q), 0, 1)
  return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
}

/// Only fast-moving rope segments hit, swept from where they were to where they are.
public func ropeHits(_ whip: Whip, center: Point, r: Double) -> Bool {
  for i in 2..<whip.points.count {
    let p = whip.points[i]
    guard hypot(p.x - p.px, p.y - p.py) * 3 > 18 else { continue }
    if segmentDistance(center, whip.points[i - 1].p, p.p) < r || segmentDistance(center, p.prev, p.p) < r { return true }
  }
  return false
}

public func segmentHitsBox(_ a: Point, _ b: Point, _ box: Box, padding: Double = 0) -> Bool {
  let x = box.x - padding, y = box.y - padding, w = box.w + padding * 2, h = box.h + padding * 2
  let r = Box(x: x, y: y, w: w, h: h)
  if r.contains(a) || r.contains(b) { return true }
  let dx = b.x - a.x, dy = b.y - a.y
  var lo = 0.0, hi = 1.0
  let sides: [(Double, Double)] = [(-dx, a.x - x), (dx, x + w - a.x), (-dy, a.y - y), (dy, y + h - a.y)]
  for (p, q) in sides {
    if p == 0 { if q < 0 { return false } } else {
      let t = q / p
      if p < 0 { lo = max(lo, t) } else { hi = min(hi, t) }
      if lo > hi { return false }
    }
  }
  return true
}

public func whipHitsBox(_ whip: Whip, _ box: Box) -> Bool {
  for i in 2..<whip.points.count {
    let p = whip.points[i]
    guard hypot(p.x - p.px, p.y - p.py) * 3 > 18 else { continue }
    if segmentHitsBox(whip.points[i - 1].p, p.p, box) || segmentHitsBox(p.prev, p.p, box) { return true }
  }
  return false
}
