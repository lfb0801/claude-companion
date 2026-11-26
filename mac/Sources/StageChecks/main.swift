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
  func tools(_ f: (inout Tools) -> Void) { var t = stage.localTools; f(&t); stage.setTools(t) }
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

check("a stationary-cursor crack plays the lash effects and answers only after collision") {
  let r = Rig([session("a", ask("p1", "permission"))])
  r.settle()
  let target = r.stage.characters["a"]!
  target.x = 800; target.y = 420; target.box = nil
  r.stage.mouse = Point(200, 350)
  r.tools { $0.whip = true }
  r.stage.crack()
  r.settle(30)
  try expect(r.answers.isEmpty, "a missed lash leaves the prompt waiting")
  try expect(r.sounds.contains(.crack))
  try expect(r.stage.particles.contains { $0.text == "SNAP" })

  // Move slowly enough that the mouse alone cannot deliver a hit.
  for x in 201...800 {
    r.stage.mouse.x = Double(x)
    r.stage.tick()
  }
  r.settle(30)
  try expect(r.answers.isEmpty, "aiming the handle leaves the prompt waiting")
  r.stage.crack()
  try expect(r.answers.isEmpty, "the crack only kicks the rope")
  r.settle(30)
  try expect(r.answers.map { "\($0.prompt) \($0.decision) \($0.source)" } == ["p1 allow whip"])
}

check("only the cannon takes every click; the whip takes clicks only on a character, to stamp") {
  var t = Tools(); t.whip = true
  try expect(!t.takesMouse); try expect(t.inHand)
  t.cannon = true; try expect(t.takesMouse)
}

func questionPrompt(_ id: String, _ qs: [Question]) -> Prompt { Prompt(id: id, kind: "question", text: qs[0].question, tool: "AskUserQuestion", questions: qs) }
let color = Question(question: "Which color?", header: "Color", options: [Option(label: "Red", description: "warm"), Option(label: "Blue", description: "cool"), Option(label: "Green")])
let size = Question(question: "Which size?", header: "Size", options: [Option(label: "S"), Option(label: "M"), Option(label: "L")])
let extras = Question(question: "Which extras?", header: "Extras", options: [Option(label: "Cheese"), Option(label: "Onion"), Option(label: "Olives")], multiSelect: true)

check("cards: clicking a question box deals one card per option on stage; left-click picks and sends") {
  let r = Rig([session("a", questionPrompt("q1", [color]))]); r.settle()
  let a = r.stage.characters["a"]!
  try expect(r.stage.openSpread(a))
  let s = r.stage.spread!
  try expect(s.cards.map(\.title) == ["Red", "Blue", "Green"])
  for (i, c) in s.cards.enumerated() {
    try expect(c.box.x >= 0 && c.box.x + c.box.w <= r.stage.width && c.box.y >= 0 && c.box.y + c.box.h <= 900, "card on stage")
    try expect(!(c.box.x < a.box!.x + a.box!.w && a.box!.x < c.box.x + c.box.w && c.box.y < a.box!.y + a.box!.h && a.box!.y < c.box.y + c.box.h), "card \(i) clear of the box")
    for d in s.cards[(i + 1)...] { try expect(c.box.x + c.box.w <= d.box.x || d.box.x + d.box.w <= c.box.x || c.box.y + c.box.h <= d.box.y || d.box.y + d.box.h <= c.box.y, "cards overlap") }
  }
  try expect(s.card(at: Point(s.cards[1].box.x + 10, s.cards[1].box.y + 10)) == 1)
  try expect(s.bannerY - 44 > a.y + 104, "the question banner sits below the character's name label")
  try expect(Spread.clean("Fast, needs a server. [work: 6-12 calls, 20K-40K]") == "Fast, needs a server.")
  r.stage.chooseCard(1)
  try expect(r.answers.count == 1)
  try expect(r.answers[0].answers == ["Which color?": "Blue"] && r.answers[0].decision == "allow" && r.answers[0].notes == nil)
  try expect(r.stage.spread == nil)
}

check("cards: right-click adds a note, sent as a note and woven into the answer text") {
  let r = Rig([session("a", questionPrompt("q1", [color]))]); r.settle()
  r.stage.openSpread(r.stage.characters["a"]!)
  r.stage.chooseCard(0, note: "but a darker shade")
  try expect(r.answers.first?.answers == ["Which color?": "Red — note: but a darker shade"], "\(String(describing: r.answers.first?.answers))")
  try expect(r.answers.first?.notes == ["Which color?": "but a darker shade"])
}

check("cards: right-click flips a card to take a note; typing, backspace, Return picks it with the note") {
  let r = Rig([session("a", questionPrompt("q1", [color]))]); r.settle()
  r.stage.openSpread(r.stage.characters["a"]!)
  r.stage.beginNote(1)
  try expect(r.stage.spread?.note?.card == 1); try expect(r.stage.noting)
  r.stage.typeNote("darker shaxx"); r.stage.deleteNoteCharacter(); r.stage.deleteNoteCharacter(); r.stage.typeNote("de, é\n")
  try expect(r.stage.spread?.note?.text == "darker shade, é ", "\(r.stage.spread?.note?.text ?? "")")
  try expect(r.answers.isEmpty, "nothing sent while writing")
  r.stage.submitNote()
  try expect(r.answers.first?.answers == ["Which color?": "Blue — note: darker shade, é"], "\(String(describing: r.answers.first?.answers))")
}

check("cards: Esc flips the note back without picking; notes are capped") {
  let r = Rig([session("a", questionPrompt("q1", [color]))]); r.settle()
  r.stage.openSpread(r.stage.characters["a"]!)
  r.stage.beginNote(0); r.stage.typeNote(String(repeating: "x", count: 900))
  try expect(r.stage.spread?.note?.text.count == Spread.noteLimit)
  r.stage.cancelNote()
  try expect(r.stage.spread != nil && r.stage.spread?.note == nil && r.answers.isEmpty)
  r.stage.beginNote(0); r.stage.submitNote()
  try expect(r.answers.first?.answers == ["Which color?": "Red"], "an empty note is just a pick")
}

check("cards: several questions come one at a time; the answer goes out after the last") {
  let r = Rig([session("a", questionPrompt("q1", [color, size]))]); r.settle()
  r.stage.openSpread(r.stage.characters["a"]!)
  r.stage.chooseCard(2)
  try expect(r.answers.isEmpty); try expect(r.stage.spread?.cards.map(\.title) == ["S", "M", "L"])
  r.stage.chooseCard(1, note: "fits loose")
  try expect(r.answers.first?.answers == ["Which color?": "Green", "Which size?": "M — note: fits loose"])
}

check("cards: multi-select toggles cards and sends on Done") {
  let r = Rig([session("a", questionPrompt("q1", [extras]))]); r.settle()
  r.stage.openSpread(r.stage.characters["a"]!)
  try expect(r.stage.spread?.cards.last?.kind == .done)
  r.stage.chooseCard(0); r.stage.chooseCard(2); r.stage.chooseCard(0); r.stage.chooseCard(1)
  try expect(r.answers.isEmpty); try expect(r.stage.spread?.picked == ["Olives", "Onion"])
  r.stage.chooseCard(3)
  try expect(r.answers.first?.answers == ["Which extras?": "Onion, Olives"])
}

check("cards: a permission deals Allow and Deny; Deny takes a note that becomes the reason") {
  let r = Rig([session("b", ask("p2", "permission"))]); r.settle()
  try expect(r.stage.openSpread(r.stage.characters["b"]!))
  try expect(r.stage.spread?.cards.map(\.title) == ["Allow", "Deny"])
  try expect(r.stage.spread?.cards.map(\.takesNote) == [false, true])
  r.stage.beginNote(1); r.stage.typeNote("use the fixture instead"); r.stage.submitNote()
  try expect(r.answers.map { "\($0.decision) \($0.source) \($0.message ?? "-") \($0.answers == nil)" } == ["deny cards use the fixture instead true"], "\(r.answers)")
  let r2 = Rig([session("b", ask("p3", "permission"))]); r2.settle()
  r2.stage.openSpread(r2.stage.characters["b"]!); r2.stage.beginNote(0)   // right-click Allow just allows
  try expect(r2.answers.map(\.decision) == ["allow"]); try expect(r2.stage.spread == nil)
}

check("cards: a plan gets its sheet (scrollable) above Approve and Keep planning; waiting for you gets Dismiss") {
  let plan = Prompt(id: "pl", kind: "plan", text: "Split the stage", plan: (1...80).map { "## Step \($0)\nDo thing \($0)." }.joined(separator: "\n"))
  let r = Rig([session("a", plan)]); r.settle()
  r.stage.openSpread(r.stage.characters["a"]!)
  let s = r.stage.spread!
  try expect(s.cards.map(\.title) == ["Approve plan", "Keep planning"])
  let sheet = s.sheet!
  try expect(sheet.y + sheet.h <= s.cards[0].box.y, "the sheet sits above the cards"); try expect(s.cards.allSatisfy { $0.box.y + $0.box.h <= 900 })
  r.stage.scrollSheet(lines: 5); r.stage.scrollSheet(lines: -9)
  try expect(r.stage.spread?.sheetScroll == 0, "can't scroll above the top")
  r.stage.scrollSheet(lines: 12); try expect(r.stage.spread?.sheetScroll == 12)
  r.stage.beginNote(1); r.stage.typeNote("merge steps 2 and 3"); r.stage.submitNote()
  try expect(r.answers.first.map { "\($0.decision) \($0.message ?? "")" } == "deny merge steps 2 and 3")
  let r2 = Rig([session("a", Prompt(id: "i", kind: "input", text: "Done."))]); r2.settle()
  r2.stage.openSpread(r2.stage.characters["a"]!)
  try expect(r2.stage.spread?.cards.map(\.title) == ["Dismiss"])
  r2.stage.chooseCard(0); try expect(r2.answers.map(\.decision) == ["allow"])
}

check("tools on dealt cards: the whip's lash picks the card it hits; the stamp requests changes") {
  let r = Rig([session("a", questionPrompt("q1", [color]))]); r.settle()
  let a = r.stage.characters["a"]!
  r.stage.mouse = Point(a.x, a.y)
  r.tools { $0.whip = true }
  r.stage.openSpread(a)
  let card = r.stage.spread!.cards[2].box, w = r.stage.whip!
  for i in w.points.indices { w.points[i] = RopePoint(x: 5, y: 5, px: 5, py: 5) }
  w.points[3] = RopePoint(x: card.x + card.w + 10, y: card.y + 20, px: card.x - 10, py: card.y + 20)  // a lash across "Green"
  try expect(r.stage.lashCards())
  try expect(r.answers.first?.answers == ["Which color?": "Green"], "\(r.answers)")
  // With cards out, swinging the whip about over the character answers nothing by itself.
  let r3 = Rig([session("c", questionPrompt("q3", [color]))]); r3.settle()
  let c3 = r3.stage.characters["c"]!
  r3.stage.mouse = Point(c3.x, c3.y); r3.tools { $0.whip = true }; r3.stage.openSpread(c3)
  for k in 0..<120 { r3.stage.mouse = Point(c3.x + sin(Double(k) * 0.5) * 60, c3.y - 200); r3.stage.tick() }
  try expect(r3.answers.allSatisfy { $0.answers != nil }, "only card picks, never a blind approve: \(r3.answers)")
  let r2 = Rig([session("b", ask("p2", "permission"))]); r2.settle()
  r2.tools { $0.stamp = true }
  r2.stage.openSpread(r2.stage.characters["b"]!)
  let allow = r2.stage.spread!.cards[0].box
  try expect(r2.stage.onSpread(Point(allow.x + 5, allow.y + 5)))
  try expect(r2.stage.stampSpread(at: Point(allow.x + 5, allow.y + 5)), "even on the Allow card, the stamp requests changes")
  try expect(r2.answers.map { "\($0.decision) \($0.source)" } == ["deny stamp"]); try expect(r2.stage.spread == nil)
  try expect(!r2.stage.stampSpread(at: Point(allow.x + 5, allow.y + 5)), "nothing left to stamp")
}

check("a phone flick uses a forceful horizontal stroke and drops after follow-through") {
  let r = Rig()
  let aim = Point(800, 350)
  r.stage.mouse = aim
  try expect(!r.stage.flickPhoneWhip(), "a flick without a hold cannot equip the whip")
  r.stage.holdPhoneWhip()
  var snapFrames: [Int] = []
  try expect(r.stage.flickPhoneWhip { snapFrames.append(r.stage.time) })
  try expect(!r.stage.flickPhoneWhip(), "one stroke at a time")
  r.stage.releasePhoneWhip()
  try expect(snapFrames.isEmpty, "acknowledge the crack, not the motion request")
  try expect(!r.stage.flickPhoneWhip(), "a released hold cannot flick again")

  var trajectory: [Point] = []
  for _ in 0..<37 {
    r.stage.tick()
    let hand = r.stage.whip!.points[0]
    trajectory.append(Point(hand.x, hand.y))
  }
  let back = trajectory.map(\.x).min()!, ahead = trajectory.map(\.x).max()!
  try expect(trajectory[8].x < aim.x - 230 && trajectory[17].x > aim.x + 150)
  try expect(ahead - back > 435 && trajectory.map(\.y).max()! - trajectory.map(\.y).min()! < 90)
  try expect(hypot(trajectory.last!.x - aim.x, trajectory.last!.y - aim.y) < 10)
  r.stage.tick()
  try expect(r.stage.whip == nil && !r.stage.tools.whip)
  try expect(snapFrames.count == 1 && (11...20).contains(snapFrames[0]))
  try expect(r.sounds.filter { $0 == .whipRush || $0 == .whipSnap || $0 == .crack } == [.whipRush, .whipSnap])
}

check("an idle phone hold only aims; a flick answers once and can finish after release") {
  let r = Rig([session("a", ask("p1", "permission")), session("b", ask("p2", "permission"))])
  r.settle()
  r.stage.mouse = Point(800, 350)
  for target in r.stage.targets { target.x = 800; target.y = 420; target.box = nil }
  r.stage.holdPhoneWhip()
  for _ in 0..<12 {
    r.stage.mouse.x = 565; r.stage.tick()
    r.stage.mouse.x = 1035; r.stage.tick()
  }
  r.stage.mouse = Point(800, 350); r.settle(60)
  try expect(r.answers.isEmpty && !r.sounds.contains(.crack), "aiming while held is not a swipe")
  try expect(r.stage.flickPhoneWhip())
  r.stage.releasePhoneWhip()
  r.settle(9)
  try expect(r.answers.isEmpty, "wind-up doesn't answer")
  r.settle(90)
  try expect(r.answers.count == 1 && r.answers.first?.source == "whip")
  try expect(r.sounds.filter { $0 == .whipSnap }.count == 1)
}

check("phone release preserves local Whip and Stamp, and local put-away cancels a held stroke") {
  let r = Rig([session("a", ask("p1", "permission")), session("b", ask("p2", "permission"))])
  r.settle()
  r.tools { $0.whip = true; $0.stamp = true }
  let localRope = r.stage.whip
  r.stage.holdPhoneWhip()
  r.stage.releasePhoneWhip()
  try expect(r.stage.whip === localRope && r.stage.tools.whip && r.stage.tools.stamp)
  let box = r.stage.characters["a"]!.box!
  try expect(r.stage.stamp(at: Point(box.x + 5, box.y + 5)))
  try expect(r.answers.first?.decision == "deny" && r.answers.first?.source == "stamp")

  let target = r.stage.characters["b"]!
  target.x = 100; target.y = 100; target.box = nil
  r.stage.mouse = Point(100, 100)
  for _ in 0..<60 {
    localRope!.points[2] = RopePoint(x: 150, y: 100, px: 50, py: 100)
    localRope!.points[1] = RopePoint(x: 50, y: 100, px: 50, py: 100)
    r.stage.swing.last = r.stage.mouse
    r.stage.tick()
  }
  try expect(r.answers.last?.decision == "allow" && r.answers.last?.source == "whip")

  r.tools { $0.whip = false }
  r.stage.holdPhoneWhip()
  r.stage.releasePhoneWhip()
  try expect(r.stage.whip == nil && r.stage.tools.stamp)
  r.stage.holdPhoneWhip()
  try expect(r.stage.flickPhoneWhip())
  r.stage.cancelPhoneWhip()
  try expect(r.stage.whip == nil && !r.stage.flickPhoneWhip())
}

check("phone Stamp uses the Mac aim and preserves open notes and unrelated prompts") {
  let r = Rig([session("a", ask("p1", "permission")), session("b", ask("p2", "permission"))])
  r.settle()
  let a = r.stage.characters["a"]!
  try expect(r.stage.openSpread(a))
  try expect(!r.stage.stampFromPhone(at: Point(5, 5)), "cannot stamp behind the spread")
  r.stage.beginNote(1)
  let card = r.stage.spread!.cards[1].box
  let point = Point(card.x + 8, card.y + 8)
  try expect(!r.stage.stampFromPhone(at: point) && r.stage.noting)
  r.stage.cancelNote()
  try expect(r.stage.stampFromPhone(at: point))
  try expect(r.answers.map { "\($0.session) \($0.decision) \($0.source)" } == ["a deny stamp"])
  try expect(r.stage.characters["b"]?.prompt?.id == "p2")

  r.settle(Layout.stampCooldown)
  let box = r.stage.characters["b"]!.box!
  try expect(r.stage.stampFromPhone(at: Point(box.x + 8, box.y + 8)))
  try expect(r.answers.last?.session == "b" && r.answers.last?.decision == "deny" && !r.stage.tools.stamp)
}

check("the stamp can be summoned on its own; it and the whip both stamp with a click") {
  var t = Tools(); t.stamp = true
  try expect(t.clickStamps && t.inHand && !t.takesMouse)
  t = Tools(); t.whip = true; try expect(t.clickStamps)
  t = Tools(); t.cannon = true; try expect(!t.clickStamps)
}

check("cards go away when the prompt is answered elsewhere") {
  let r = Rig([session("a", questionPrompt("q1", [color])), session("b", ask("p2", "permission"))]); r.settle()
  r.stage.openSpread(r.stage.characters["a"]!)
  r.apply(.answered("a", prompt: "q1", source: "terminal"))
  try expect(r.stage.spread == nil)
  r.apply(.prompt("a", questionPrompt("q2", [color]))); r.settle()
  r.stage.openSpread(r.stage.characters["a"]!)
  r.tools { $0.whip = true }
  r.stage.answer(r.stage.characters["a"], decision: "allow", source: "whip")
  try expect(r.stage.spread == nil, "the whip answered it")
}

check("waiting for you: on stage for a moment, then off on its own and not back for the same wait; a real prompt still stays") {
  let r = Rig([session("a"), session("b")])
  r.apply(.prompt("a", Prompt(id: "i1", kind: "input", text: "Done.")))
  r.apply(.prompt("b", ask("p1", "permission")))
  r.settle()
  try expect(r.stage.characters["a"] != nil)
  r.stage.mouse = Point(5, 5)
  for _ in 0..<(Layout.inputLinger + 5) { r.stage.tick() }
  try expect(r.stage.characters["a"] == nil, "left on its own"); try expect(r.stage.characters["b"] != nil, "the permission prompt stays")
  r.apply(.session(session("a")))
  try expect(r.stage.characters["a"] == nil, "a later sync does not bring the same wait back")
  try expect(r.sessions["a"]?.prompt?.id == "i1", "the session still counts as waiting")
  r.apply(.prompt("a", Prompt(id: "i2", kind: "input", text: "Done again.")))
  try expect(r.stage.characters["a"] != nil, "a new wait comes on again")
  let a = r.stage.characters["a"]!
  r.settle(); r.stage.mouse = Point(a.x, a.y)
  for _ in 0..<(Layout.inputLinger + 5) { r.stage.tick() }
  try expect(r.stage.characters["a"] != nil, "stays while you point at it")
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
