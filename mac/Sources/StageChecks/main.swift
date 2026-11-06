// Checks for StageCore. Run: swift run StageChecks   (exit code 1 on any failure)
// Ported from tests/physics.test.mjs and tests/stage.test.mjs.
import Foundation
import StageCore

nonisolated(unsafe) var failures = 0, passed = 0
func check(_ name: String, _ body: () throws -> Void) {
  do { try body(); passed += 1; print("✔ \(name)") } catch { failures += 1; print("✖ \(name)\n    \(error)") }
}
struct Fail: Error, CustomStringConvertible { let description: String }
func expect(_ ok: Bool, _ what: @autoclosure () -> String = "", line: Int = #line) throws { if !ok { throw Fail(description: "line \(line): \(what())") } }

let ask = { (id: String, kind: String) in Prompt(id: id, kind: kind, text: "Bash: npm test (\(id))", detail: "Run the tests") }
func session(_ id: String, _ prompt: Prompt? = nil) -> Session { Session(id: id, cwd: "/work/\(id)", folder: "proj-\(id)", title: "Task \(id)", prompt: prompt) }

/// A stage wired the way the app wires it: an answer clears the prompt.
final class Rig {
  let stage = Stage(width: 1600)
  var sessions = Sessions()
  var answers: [Answer] = []
  var sounds: [Sound] = []
  init(_ list: [Session] = []) {
    stage.onAnswer = { [unowned self] a in answers.append(a); sessions.answered(a.session, prompt: a.prompt); stage.sync(sessions.all) }
    stage.onSound = { [unowned self] in sounds.append($0) }
    apply(.snapshot(list))
  }
  func apply(_ e: ServerEvent) { sessions.apply(e); stage.sync(sessions.all) }
  func settle(_ n: Int = Layout.enter + 1) { for _ in 0..<n { stage.tick() } }
  func tools(_ f: (inout Tools) -> Void) { var t = stage.tools; f(&t); stage.setTools(t) }
}

check("rope stays finite and inside the stage through rapid sweeps and repeated flicks") {
  let w = Whip()
  for i in 0..<1800 {
    if i % 45 == 0 { w.kick() }
    w.step(Point(800 + sin(Double(i) * 0.2) * 750, 450 + cos(Double(i) * 0.13) * 400), width: 1600, height: 900)
    try expect(w.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1600 && $0.y >= 0 && $0.y <= 900 })
  }
  try expect(w.points.count == 28)
}

check("collision uses moving segments and catches a swept lash") {
  let w = Whip(0, 0)
  for i in w.points.indices { w.points[i] = RopePoint(x: 100, y: 100, px: 100, py: 100) }
  try expect(!ropeHits(w, center: Point(100, 100), r: 20))
  w.points[5] = RopePoint(x: 300, y: 100, px: 0, py: 100)
  try expect(ropeHits(w, center: Point(200, 100), r: 20))
  try expect(segmentDistance(Point(50, 10), Point(0, 0), Point(100, 0)) == 10)
}

check("small cursor jitter stays quiet while a deliberate flick still cracks") {
  let w = Whip(800, 350)
  var cracks = 0, maxSpeed = 0.0
  for i in 0..<360 {
    if w.step(Point(800 + sin(Double(i)) * 2, 350), width: 1600, height: 900) { cracks += 1 }
    let t = w.points.last!; maxSpeed = max(maxSpeed, hypot(t.x - t.px, t.y - t.py) * 3)
  }
  try expect(cracks == 0, "cracks \(cracks)"); try expect(maxSpeed < 5, "speed \(maxSpeed)")
  w.kick()
  for _ in 0..<60 { if w.step(Point(800, 350), width: 1600, height: 900) { cracks += 1 } }
  try expect(cracks > 0)
}

check("a moving rope segment that crosses a box hits it; a resting rope or a miss does not") {
  let box = Box(x: 100, y: 100, w: 50, h: 50)
  try expect(segmentHitsBox(Point(0, 125), Point(300, 125), box))
  try expect(!segmentHitsBox(Point(0, 0), Point(300, 0), box))
  let w = Whip(0, 0)
  for i in w.points.indices { w.points[i] = RopePoint(x: 125, y: 125, px: 125, py: 125) }
  try expect(!whipHitsBox(w, box))
  w.points[5] = RopePoint(x: 300, y: 125, px: 0, py: 125)
  try expect(whipHitsBox(w, box))
}

check("a shot picks the nearest character or prompt box along its path") {
  final class T: Target { let x, y, r: Double; let box: Box?; let id: String; init(_ id: String, _ x: Double, _ y: Double, box: Box? = nil) { self.id = id; self.x = x; self.y = y; r = 20; self.box = box } }
  let near = T("a", 200, 100), far = T("b", 380, 100), boxed = T("c", 900, 900, box: Box(x: 50, y: 80, w: 40, h: 40))
  try expect(projectileTarget(from: Point(0, 100), to: Point(400, 100), [far, near])?.id == "a")
  try expect(projectileTarget(from: Point(0, 100), to: Point(400, 100), [near, boxed])?.id == "c")
  try expect(projectileTarget(from: Point(0, 500), to: Point(400, 500), [near]) == nil)
}

check("one swing is spent by a hit and re-arms after a pause or a reversal") {
  var g = SwingGate()
  g.consume(tick: 0); try expect(g.spent)
  for i in 0..<12 { g.move(g.last, tick: i) }
  g.move(Point(g.last.x + 20, g.last.y), tick: 20); try expect(!g.spent)
  g.consume(tick: 30)
  g.move(Point(g.last.x - 20, g.last.y), tick: 50); try expect(!g.spent)
}

check("server events decode: snapshot, prompt with questions, answered with a prompt id, log, junk ignored") {
  let snap = ServerEvent.decode(#"{"type":"snapshot","sessions":[{"id":"a","cwd":"/w/a","folder":"a","title":"","prompt":null}]}"#)
  try expect(snap == .snapshot([Session(id: "a", cwd: "/w/a", folder: "a", title: "")]))
  let p = ServerEvent.decode(#"{"type":"prompt","id":"a","prompt":{"id":"p1","kind":"question","text":"Which?","detail":"Red · Blue","tool":"AskUserQuestion","questions":[{"question":"Which?","header":"Color","options":[{"label":"Red","description":"r"},{"label":"Blue"}],"multiSelect":false}]}}"#)
  guard case .prompt("a", let prompt) = p else { throw Fail(description: "prompt: \(String(describing: p))") }
  try expect(prompt.questions?.first?.options.map(\.label) == ["Red", "Blue"])
  try expect(ServerEvent.decode(#"{"type":"answered","id":"a","prompt":"p1","source":"terminal","decision":"allow"}"#) == .answered("a", prompt: "p1", source: "terminal"))
  try expect(ServerEvent.decode(#"{"type":"log","id":"a","lines":[{"kind":"tool","text":"● Bash(ls)"}]}"#) == .log("a", [LogLine(kind: "tool", text: "● Bash(ls)")]))
  try expect(ServerEvent.decode("not json") == nil); try expect(ServerEvent.decode(#"{"type":"wat"}"#) == nil)
}

check("sessions: update in place keeps a pending prompt; only the current prompt's answer clears it") {
  var s = Sessions()
  s.apply(.snapshot([session("a"), session("b")]))
  s.apply(.prompt("a", ask("p1", "permission")))
  s.apply(.session(Session(id: "a", cwd: "/work/a", folder: "proj-a", title: "Renamed")))
  try expect(s["a"]?.title == "Renamed"); try expect(s["a"]?.prompt?.id == "p1")
  s.apply(.answered("a", prompt: "old", source: nil)); try expect(s["a"]?.prompt?.id == "p1")
  s.apply(.answered("a", prompt: "p1", source: nil)); try expect(s["a"]?.prompt == nil)
  s.apply(.end("b")); try expect(s.all.map(\.id) == ["a"])
}

check("a character is on stage only while its session needs you: in from the right, out after the answer") {
  let r = Rig([session("a"), session("b")])
  try expect(r.stage.all.isEmpty)
  r.apply(.prompt("a", ask("p1", "permission")))
  let a = r.stage.characters["a"]!
  try expect(r.stage.enterOffset(a) > 0)
  try expect(a.folder == "proj-a" && a.title == "Task a" && a.box != nil)
  r.settle(); try expect(r.stage.enterOffset(a) == 0); try expect(a.x > 1400)
  r.apply(.answered("a", prompt: "p1", source: "terminal"))
  try expect(r.stage.all.isEmpty); try expect(r.stage.departures.count == 1)
  r.settle(80); try expect(r.stage.departures.isEmpty)
}

check("as many sessions as fit (10 on a laptop, 15 on a wide screen): no box overlaps a box or a character") {
  try expect(Layout.capacity(width: 1440) == 10); try expect(Layout.capacity(width: 1600) == 15); try expect(Layout.capacity(width: 900) == 5)
  for width in [1600.0, 1440, 1512, 2560, 900] {
    let r = Rig((0..<Layout.capacity(width: width)).map { session("s\($0)", ask("p\($0)", "permission")) })
    r.stage.relayout(width: width)
    var rects: [(String, Box)] = []
    for c in r.stage.all { rects.append(("box \(c.id)", c.box!)); rects.append(("body \(c.id)", Box(x: c.x - c.r, y: c.y - 62, w: c.r * 2, h: 166))) }
    for (n, p) in rects {
      try expect(p.x >= 0 && p.y >= 0 && p.x + p.w <= width && p.y + p.h <= 900, "\(n) on stage at width \(width)")
      for (m, q) in rects where n < m { try expect(!(p.x < q.x + q.w && q.x < p.x + p.w && p.y < q.y + q.h && q.y < p.y + p.h), "\(n) overlaps \(m) at width \(width)") }
    }
  }
}

check("whip: one swing answers one prompt with allow, even with many overlapping characters") {
  let r = Rig((0..<6).map { session("s\($0)", ask("p\($0)", "permission")) }); r.settle()
  r.tools { $0.whip = true }
  for c in r.stage.all { c.x = 100; c.y = 100; c.box = Box(x: 0, y: 0, w: 10, h: 10) }
  r.stage.mouse = Point(100, 100)
  let w = r.stage.whip!
  for _ in 0..<60 {
    // a lash through the crowd every frame, the swing gate lets one through
    w.points[2] = RopePoint(x: 150, y: 100, px: 50, py: 100); w.points[1] = RopePoint(x: 50, y: 100, px: 50, py: 100)
    r.stage.swing.last = r.stage.mouse
    r.stage.tick()
  }
  try expect(r.answers.count == 1, "\(r.answers.count) answers")
  try expect(r.answers[0].decision == "allow" && r.answers[0].source == "whip")
}

check("cannon: a shot answers the nearest prompt with allow and is spent") {
  let r = Rig([session("a", ask("p1", "permission")), session("b", ask("p2", "permission"))]); r.settle()
  r.tools { $0.cannon = true }
  let b = r.stage.characters["a"]!.box!
  r.stage.shots = [Shot(x: b.x - 10, y: b.y + 40, px: b.x - 40, py: b.y + 40, vx: 30, vy: 0, life: 20, angle: 0)]
  r.stage.tick(); r.stage.tick()
  try expect(r.answers.map { "\($0.session) \($0.prompt) \($0.decision) \($0.source)" } == ["a p1 allow cannon"])
  try expect(r.stage.shots.isEmpty)
}

check("stamp: a click on a prompt denies it, empty ground marks NO TARGET, the cooldown gates repeats") {
  let r = Rig([session("a", ask("p1", "permission"))]); r.settle()
  r.tools { $0.whip = true }
  try expect(r.stage.stamp(at: Point(10, 10))); try expect(r.answers.isEmpty); try expect(r.stage.marks.first?.text == "NO TARGET")
  let b = r.stage.characters["a"]!.box!
  try expect(!r.stage.stamp(at: Point(b.x + 5, b.y + 5)), "cooling down")
  for _ in 0..<Layout.stampCooldown { r.stage.tick() }
  try expect(r.stage.stamp(at: Point(b.x + 5, b.y + 5)))
  try expect(r.answers.map { "\($0.session) \($0.decision) \($0.source)" } == ["a deny stamp"])
  try expect(r.stage.departures.first?.hold == Layout.denyHold); try expect(r.stage.departures.first?.box != nil)
}

check("Intern: approves every waiting prompt in every session, one at a time, oldest first") {
  let r = Rig([session("a", ask("p1", "permission")), session("b", ask("p2", "permission")), session("c", ask("p3", "permission"))]); r.settle()
  r.tools { $0.intern = true }
  for _ in 0..<1500 where r.answers.count < 3 { r.stage.tick() }
  try expect(r.answers.map { "\($0.session) \($0.decision) \($0.source)" } == ["a allow intern", "b allow intern", "c allow intern"], "\(r.answers)")
  r.apply(.prompt("b", ask("p4", "permission")))
  for _ in 0..<1500 where r.answers.count < 4 { r.stage.tick() }
  try expect(r.answers.last?.prompt == "p4")
  r.tools { $0.intern = false }; try expect(r.stage.intern == nil)
}

check("a prompt gets one answer even when several tools land on it at once") {
  let r = Rig([session("a", ask("p1", "permission"))]); r.settle()
  let a = r.stage.characters["a"]!
  try expect(r.stage.answer(a, decision: "allow", source: "whip"))
  try expect(!r.stage.answer(a, decision: "deny", source: "stamp"))
  try expect(r.answers.count == 1)
}

check("SessionStart: a short entrance, then off again unless a prompt arrives meanwhile") {
  let r = Rig([session("a"), session("b")])
  r.stage.greet(session("a")); try expect(r.stage.characters["a"] != nil)
  r.apply(.session(session("a"))); try expect(r.stage.characters["a"] != nil, "a sync while greeting keeps it")
  for _ in 0..<Layout.greet { r.stage.tick() }
  try expect(r.stage.characters["a"] == nil); try expect(r.stage.departures.count == 1)
  r.stage.greet(session("b")); r.apply(.prompt("b", ask("p1", "permission")))
  for _ in 0..<(Layout.greet * 2) { r.stage.tick() }
  try expect(r.stage.characters["b"]?.greet == 0)
}

check("each project gets a stable hue and accessory from its folder") {
  try expect(Layout.looks("/work/a") == Layout.looks("/work/a"))
  let all = Set((0..<40).map { "\(Layout.looks("/work/p\($0)"))" })
  try expect(all.count > 30)
  let r = Rig([session("a", ask("p1", "permission"))])
  try expect(r.stage.characters["a"]!.hue == Layout.looks("/work/a").hue)
}

check("summoning the whip and the cannon cue their clips once per summon, never while muted") {
  let r = Rig()
  r.tools { $0.whip = true }; r.stage.crack(); r.tools { $0.cannon = true }
  try expect(r.sounds.filter { $0 == .whipCue }.count == 1); try expect(r.sounds.filter { $0 == .cannonCue }.count == 1)
  r.tools { $0.whip = false; $0.muted = true }; try expect(r.sounds.contains(.stopCues))
  r.tools { $0.whip = true }; try expect(r.sounds.filter { $0 == .whipCue }.count == 1, "muted")
}

check("pick finds the character or its prompt box under the pointer") {
  let r = Rig([session("a", ask("p1", "permission"))])
  try expect(r.stage.pick(Point(5, 5)) == nil)
  r.settle()
  let a = r.stage.characters["a"]!
  try expect(r.stage.pick(Point(a.x, a.y)) === a)
  try expect(r.stage.pick(Point(a.box!.x + 3, a.box!.y + 3)) === a)
}

check("the whip: holding it still answers nothing; the handle's stamp denies only where you click") {
  let r = Rig([session("a", ask("p1", "permission")), session("b", ask("p2", "permission"))]); r.settle()
  let a = r.stage.characters["a"]!
  r.stage.mouse = Point(a.x, a.y)
  r.tools { $0.whip = true }
  for _ in 0..<120 { r.stage.tick() }   // a still hand over a character: the lash hangs, no hit
  try expect(r.answers.isEmpty, "\(r.answers)")
  let b = r.stage.characters["b"]!.box!
  try expect(r.stage.stamp(at: Point(b.x + 5, b.y + 5)))
  try expect(r.answers.map { "\($0.session) \($0.decision) \($0.source)" } == ["b deny stamp"])
  try expect(r.stage.characters["a"] != nil, "a is untouched")
}

check("only the cannon takes every click; the whip takes clicks only on a character, to stamp") {
  var t = Tools(); t.whip = true
  try expect(!t.takesMouse); try expect(t.inHand)
  t.cannon = true; try expect(t.takesMouse)
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
