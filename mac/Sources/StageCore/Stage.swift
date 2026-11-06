// Stage state and rules, ported from theater.js. Drawing lives in the app target.
// One character per session; a character is on stage only while its session needs you.
// Whip, cannon and Intern answer "allow", the stamp answers "deny"; only the first answer counts.
import Foundation

public enum Sound: Equatable, Sendable {
  case ping(Int), warn, whoosh, thunk(light: Bool), toggle(on: Bool), tally, crack, approve, fire
  case whipCue, cannonCue, stopCues
}

/// The whip approves by swinging (no click); a click with it stamps with the back of the handle (deny).
public struct Tools: Equatable, Sendable {
  public var whip = false, cannon = false, intern = false, muted = false
  public init() {}
  public var anyArmed: Bool { whip || cannon || intern }
  /// Tools in your hand: they follow the cursor (the Intern works on its own).
  public var inHand: Bool { whip || cannon }
  /// The cannon takes every click (hold to fire). The whip only takes clicks on a character or
  /// its prompt (to stamp); anywhere else your clicks still go to your other apps.
  public var takesMouse: Bool { cannon }
}

public enum Tone: Sendable { case lime, amber, red, cream, grey }

public struct Particle: Sendable { public var x, y, vx, vy: Double; public var life: Int; public var text: String; public var tone: Tone; public var angle: Double }
public struct Shot: Sendable {
  public var x, y, px, py, vx, vy: Double; public var life: Int; public var angle: Double; public var spent = false
  public init(x: Double, y: Double, px: Double, py: Double, vx: Double, vy: Double, life: Int, angle: Double) { self.x = x; self.y = y; self.px = px; self.py = py; self.vx = vx; self.vy = vy; self.life = life; self.angle = angle }
}
public struct Slam: Sendable { public var x, y: Double; public var age = 0 }
public struct Mark: Sendable { public var x, y: Double; public var text: String; public var life: Int; public let max: Int }
public struct StampMark: Sendable { public var text: String; public var approve: Bool; public var life: Int; public let max: Int }

public final class Character: Target {
  public let id: String
  public let slot: Int
  public var x: Double, y: Double
  public let r: Double = 78
  public let hue: Double
  public let accessory: String
  public var folder = "", title = "", cwd = ""
  public var prompt: Prompt? = nil
  public var box: Box? = nil
  public var boxBorn = 0
  public var answered = false
  public var decision: String? = nil
  public var hurt = 0, enter = 0, greet = 0
  public var stamp: StampMark? = nil
  init(id: String, slot: Int, at p: Point, hue: Double, accessory: String) { self.id = id; self.slot = slot; x = p.x; y = p.y; self.hue = hue; self.accessory = accessory }
}

/// A character leaving to the right; denied ones hold their box a moment first.
public struct Departure: Sendable {
  public var id: String, folder: String, title: String, hue: Double, accessory: String
  public var x: Double, y: Double, x0: Double, r: Double
  public var box: Box?, prompt: Prompt?, stamp: StampMark?
  public var hold: Int, life: Int, age = 0, hurt: Int
  public let max: Int
}

public enum Layout {
  public static let enter = 45, depart = 60, denyHold = 45, slam = 36, stampCooldown = 105, greet = 110
  public static let column = 530.0, row = 170.0, perColumn = 5, boxW = 340.0, boxH = 116.0
  static let ring: [(Double, Double)] = [(0, 0), (-87, -70), (-44, 35), (-131, 0)]
  public static let accessories = ["none", "cap", "bow", "glasses", "headphones", "crown", "antenna"]

  /// Columns whose prompt box still fits left of its character on a stage this wide (at least 1).
  public static func columns(width: Double) -> Int { max(1, min(3, Int((width - 90 - 78 - 12 - boxW - 10) / column) + 1)) }
  /// Cells that fit without overlap: 5 per column.
  public static func capacity(width: Double) -> Int { columns(width: width) * perColumn }
  /// Cells in columns of 5 from the right edge; past capacity, the grid repeats with an offset.
  public static func slot(_ k: Int, width: Double) -> Point {
    let cap = capacity(width: width)
    let cell = k % cap
    let offset: (Double, Double) = ring[(k / cap) % 4]
    let col = Double(cell / perColumn), rowIndex = Double(cell % perColumn)
    let x: Double = width - 90 - col * column + offset.0
    let y: Double = 115 + rowIndex * row + offset.1
    return Point(x, y)
  }
  public static func box(for c: Character) -> Box {
    Box(x: max(10, c.x - c.r - 12 - boxW), y: max(10, min(900 - boxH - 10, c.y - boxH / 2)), w: boxW, h: boxH)
  }
  /// The same project always looks the same: FNV-1a over the folder path.
  public static func looks(_ cwd: String) -> (hue: Double, accessory: String) {
    var h: UInt32 = 2166136261
    for u in cwd.utf16 { h ^= UInt32(u); h = h &* 16777619 }
    return (Double(h % 360), accessories[Int((h >> 9) % UInt32(accessories.count))])
  }
}

public final class Stage {
  /// Logical stage: always 900 high; as wide as the screen at that scale.
  public var width: Double
  public let height = 900.0
  public private(set) var order: [String] = []
  public private(set) var characters: [String: Character] = [:]
  public var departures: [Departure] = []
  public var particles: [Particle] = []
  public var shots: [Shot] = []
  public var slams: [Slam] = []
  public var marks: [Mark] = []
  public var mouse = Point(850, 450)
  public private(set) var time = 0
  public private(set) var tools = Tools()
  public private(set) var whip: Whip? = nil
  public private(set) var intern: AutoWhipper? = nil
  public var swing = SwingGate()
  public var firing = false
  public private(set) var cannonEntry = 0, internFlash = 0, stampReady = 0
  public private(set) var shake = 0.0
  var lastFire = 0, lastSound = -100
  public var onAnswer: (Answer) -> Void = { _ in }
  public var onSound: (Sound) -> Void = { _ in }

  public init(width: Double = 1600) { self.width = width }

  public var all: [Character] { order.compactMap { characters[$0] } }
  public var cannonOrigin: Point { Point(145, 790) }

  // MARK: sessions in

  /// Characters follow the sessions: on stage while a prompt is pending, off stage otherwise.
  public func sync(_ sessions: [Session]) {
    let known = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for c in all where known[c.id]?.prompt == nil {
      if c.greet > 0 && known[c.id] != nil { c.prompt = nil; c.box = nil; continue }
      depart(c); remove(c.id)
    }
    for s in sessions {
      guard let p = s.prompt else { continue }
      let c = characters[s.id] ?? arrive(s)
      if c.prompt?.id != p.id {
        c.prompt = p; c.answered = false; c.decision = nil; c.stamp = nil; c.greet = 0
        c.box = Layout.box(for: c); c.boxBorn = time
        onSound(.warn)
      }
    }
    for c in all { if let s = known[c.id] { c.folder = s.folder ?? ""; c.title = s.title ?? ""; c.cwd = s.cwd ?? "" } }
  }

  @discardableResult
  func arrive(_ s: Session) -> Character {
    let used = Set(all.map(\.slot))
    var k = 0
    while used.contains(k) { k += 1 }
    let look = Layout.looks(s.cwd ?? s.folder ?? s.id)
    let c = Character(id: s.id, slot: k, at: Layout.slot(k, width: width), hue: look.hue, accessory: look.accessory)
    c.enter = Layout.enter; c.folder = s.folder ?? ""; c.title = s.title ?? ""; c.cwd = s.cwd ?? ""
    characters[s.id] = c; order.append(s.id)
    onSound(.ping(characters.count))
    return c
  }

  func remove(_ id: String) { characters[id] = nil; order.removeAll { $0 == id } }

  /// SessionStart: a short entrance, then off stage again unless a prompt arrived meanwhile.
  public func greet(_ s: Session) {
    guard characters[s.id] == nil else { return }
    arrive(s).greet = Layout.greet
  }

  /// Screen moved or resized: re-seat everyone in their cells.
  public func relayout(width: Double) {
    self.width = width
    for c in all {
      let p = Layout.slot(c.slot, width: width); c.x = p.x; c.y = p.y
      if c.box != nil { c.box = Layout.box(for: c) }
    }
  }

  func depart(_ c: Character) {
    let denied = c.decision == "deny"
    if c.enter > 0 && c.decision == nil { return }
    departures.append(Departure(id: c.id, folder: c.folder, title: c.title, hue: c.hue, accessory: c.accessory, x: c.x, y: c.y, x0: c.x, r: c.r,
                                box: denied ? c.box : nil, prompt: denied ? c.prompt : nil, stamp: c.stamp,
                                hold: denied ? Layout.denyHold : 0, life: Layout.depart, hurt: c.hurt, max: Layout.depart))
    if !denied { onSound(.whoosh) }
  }

  // MARK: tools

  public func setTools(_ t: Tools) {
    let was = tools
    tools = t
    if t.intern && !was.intern { intern = AutoWhipper() }
    if !t.intern { intern = nil }
    if t.cannon && !was.cannon { cannonEntry = 90; if !t.muted { onSound(.cannonCue) } }
    if t.whip && !was.whip { whip = Whip(mouse.x, mouse.y, width: width, height: height); swing = SwingGate(); swing.last = mouse; if !t.muted { onSound(.whipCue) } }
    if !t.whip { whip = nil }
    if t.muted && !was.muted { onSound(.stopCues) }
  }

  public func crack() { guard let w = whip else { return }; w.kick(); swing.reset() }

  public func fire() {
    let o = cannonOrigin, dx = mouse.x - o.x, dy = mouse.y - o.y, d = max(hypot(dx, dy), 1)
    shots.append(Shot(x: o.x + dx / d * 100, y: o.y + dy / d * 100, px: o.x, py: o.y, vx: dx / d * 31, vy: dy / d * 31, life: 100, angle: atan2(dy, dx)))
    onSound(.fire)
    burst(o.x + dx / d * 120, o.y + dy / d * 120, "✓", .lime, 3)
  }

  /// Characters a tool can answer: waiting, unanswered, fully on stage.
  public var targets: [Character] { all.filter { $0.prompt != nil && !$0.answered && $0.enter <= 0 } }

  @discardableResult
  public func answer(_ c: Character?, decision: String, source: String) -> Bool {
    guard let c, let p = c.prompt, !c.answered else { return false }
    c.answered = true; c.decision = decision
    switch source {
    case "stamp": c.stamp = StampMark(text: "DENIED", approve: false, life: 150, max: 150); onSound(.thunk(light: false)); addShake(9); burst(c.x, c.y, "✕", .red, 6)
    case "intern": c.hurt = 28; c.stamp = StampMark(text: "APPROVED", approve: true, life: 50, max: 50); internFlash = 26; burst(c.x, c.y, "✓✓✓", .lime, 8); onSound(.tally)
    case "cannon": burst(c.x, c.y, "LGTM", .lime, 10); onSound(.approve)
    default: c.hurt = 28; burst(c.x, c.y, "CONTINUE", .lime, 5); crackSound()
    }
    onAnswer(Answer(session: c.id, prompt: p.id, decision: decision, source: source))
    return true
  }

  /// The character (or its prompt box) under a point, whatever it is doing.
  public func pick(_ p: Point) -> Character? {
    let list = all.filter { $0.enter <= 0 }.reversed()
    if let c = list.first(where: { $0.box?.contains(p) == true }) { return c }
    return list.first { hypot($0.x - p.x, $0.y - p.y) < $0.r * 1.3 }
  }
  public func onBox(_ c: Character, _ p: Point) -> Bool { c.box?.contains(p) == true }

  @discardableResult
  public func stamp(at p: Point) -> Bool {
    guard time >= stampReady else { return false }
    stampReady = time + Layout.stampCooldown
    slams.append(Slam(x: p.x, y: p.y))
    let list = targets.reversed()
    let c = list.first(where: { $0.box?.contains(p) == true }) ?? list.first { hypot($0.x - p.x, $0.y - p.y) < $0.r * 1.3 }
    if !answer(c, decision: "deny", source: "stamp") {
      marks.append(Mark(x: p.x, y: p.y, text: "NO TARGET", life: 110, max: 110)); onSound(.thunk(light: true)); addShake(4)
    }
    return true
  }

  public func burst(_ x: Double, _ y: Double, _ text: String, _ tone: Tone, _ count: Int) {
    for i in 0..<count {
      let a = Double(i) * 2.4
      particles.append(Particle(x: x, y: y, vx: cos(a) * Double(3 + i % 7), vy: sin(a) * 7 - 3, life: 65, text: i % 3 == 0 ? text : "✦", tone: tone, angle: Double(i) * 0.8))
    }
  }
  func addShake(_ p: Double) { shake = max(shake, p) }
  func crackSound() {
    guard time - lastSound > 15 else { return }
    onSound(.crack); lastSound = time
    if let t = whip?.points.last { burst(t.x, t.y, "SNAP", .cream, 6) }
  }

  public func enterOffset(_ c: Character) -> Double {
    let k = Double(c.enter) / Double(Layout.enter)
    return (width + 150 - c.x) * k * k * k
  }

  // MARK: frame

  public func tick() {
    time += 1
    if tools.cannon && firing && time - lastFire > 6 { fire(); lastFire = time }
    if cannonEntry > 0 { cannonEntry -= 1 }
    if internFlash > 0 { internFlash -= 1 }
    for c in all {
      if c.hurt > 0 { c.hurt -= 1 }
      if var s = c.stamp { s.life -= 1; c.stamp = s.life > 0 ? s : nil }
      if c.enter > 0 { c.enter -= 1 }
      if c.greet > 0 { c.greet -= 1; if c.greet == 0 && c.prompt == nil { depart(c); remove(c.id) } }
    }
    shake = shake > 0.3 ? shake * 0.88 : 0
    if let i = intern, let e = i.step(all, width: width, height: height) { answer(characters[e], decision: "allow", source: "intern") }
    if let w = whip {
      swing.move(mouse, tick: time)
      if w.step(mouse, width: width, height: height) { crackSound() }
      if !swing.spent {
        let list = Array(targets.reversed())
        if let c = list.first(where: { ropeHits(w, center: Point($0.x, $0.y), r: $0.r) }) ?? list.first(where: { $0.box.map { b in whipHitsBox(w, b) } == true }) {
          swing.consume(tick: time); answer(c, decision: "allow", source: "whip")
        }
      }
    }
    for i in shots.indices where !shots[i].spent && shots[i].life > 0 {
      shots[i].px = shots[i].x; shots[i].py = shots[i].y
      shots[i].x += shots[i].vx; shots[i].y += shots[i].vy; shots[i].life -= 1
      if let c = projectileTarget(from: Point(shots[i].px, shots[i].py), to: Point(shots[i].x, shots[i].y), targets) {
        shots[i].spent = true; shots[i].life = 0; answer(c, decision: "allow", source: "cannon")
      }
    }
    for i in slams.indices { slams[i].age += 1 }
    slams.removeAll { $0.age >= Layout.slam }
    for i in marks.indices { marks[i].life -= 1 }
    marks.removeAll { $0.life <= 0 }
    for i in departures.indices {
      if var s = departures[i].stamp, s.life > 0 { s.life -= 1; departures[i].stamp = s }
      if departures[i].hold > 0 {
        departures[i].hold -= 1
        if departures[i].hold == 0 { burst(departures[i].x, departures[i].y, "DENIED", .red, 10); onSound(.whoosh) }
        continue
      }
      departures[i].age += 1
      departures[i].x += 3 + Double(departures[i].age * departures[i].age) * 0.008
      departures[i].hurt = max(0, departures[i].hurt - 1)
      departures[i].life -= 1
    }
    departures.removeAll { $0.life <= 0 }
    shots.removeAll { $0.life <= 0 }
    for i in particles.indices { particles[i].x += particles[i].vx; particles[i].y += particles[i].vy; particles[i].vy += 0.12; particles[i].life -= 1; particles[i].angle += 0.025 }
    particles.removeAll { $0.life <= 0 }
  }
}

/// The Approval Intern: walks to the oldest waiting prompt, in any session, and whips it.
public final class AutoWhipper {
  public private(set) var whip: Whip? = nil
  var target: String? = nil
  var frame = 0, cooldown = 0
  public private(set) var hand = Point(820, 650)
  public init() {}

  /// Returns the id of the character it just hit.
  public func step(_ all: [Character], width: Double, height: Double) -> String? {
    let waiting = all.filter { $0.prompt != nil && !$0.answered && $0.enter <= 0 }
    if cooldown > 0 { cooldown -= 1; return nil }
    var t = waiting.first { $0.id == target }
    if t == nil {
      t = waiting.min { $0.boxBorn < $1.boxBorn }
      target = t?.id; frame = 0; whip = nil
    }
    guard let c = t else { hand = Point(width / 2, 650); return nil }
    let k = min(1, Double(frame) / 20)
    hand = Point(c.x - 330 + k * 460, c.y - 95 + sin(k * .pi) * 80)
    if whip == nil { whip = Whip(hand.x, hand.y, width: width, height: height) }
    if frame == 6 { whip!.kick() }
    whip!.step(hand, width: width, height: height)
    frame += 1
    if frame >= 12 && (ropeHits(whip!, center: Point(c.x, c.y), r: c.r) || c.box.map { whipHitsBox(whip!, $0) } == true) {
      target = nil; cooldown = 30
      return c.id
    }
    if frame > 65 { target = nil; whip = nil }
    return nil
  }
}
