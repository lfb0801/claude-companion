// Answering on the stage with cards. Click a prompt box (no tool armed) and cards are dealt under it:
// - a question: one card per option. Left-click picks; right-click flips the card to add a note.
//   Several questions come one at a time; multi-select questions get a Done card.
// - a permission: Allow and Deny. Right-click Deny to write why; Claude gets it as the reason.
// - a plan: the plan on a scrollable sheet, with Approve plan and Keep planning (right-click: what to change).
// - waiting for you: a single Dismiss card.
import Foundation

public struct SpreadCard: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case option(String), done, allow, deny }
  public let kind: Kind
  public let title: String
  public let detail: String
  public var box: Box
  /// Whether right-click flips this card to take a note.
  public var takesNote: Bool { switch kind { case .option, .deny: true; default: false } }
}

public struct Spread: Sendable {
  public let session: String
  public let prompt: String
  /// question | permission | plan | input
  public let kind: String
  public let title: String
  public let detail: String
  public let questions: [Question]
  public let plan: String
  public private(set) var index = 0
  public private(set) var answers: [String: String] = [:]
  public private(set) var notes: [String: String] = [:]
  /// Picked labels for the current multi-select question.
  public private(set) var picked: Set<String> = []
  public private(set) var cards: [SpreadCard] = []
  public private(set) var dealtAt = 0
  /// The plan sheet (plans only) and how far it is scrolled, in lines.
  public private(set) var sheet: Box? = nil
  public var sheetScroll = 0
  /// A card flipped over to take a note (right-click): which card, what's typed, when it flipped.
  public struct Note: Equatable, Sendable { public let card: Int; public var text: String; public let since: Int }
  public internal(set) var note: Note? = nil
  public static let noteLimit = 400

  public static let cardW = 230.0, cardH = 128.0, gap = 18.0

  public var isQuestion: Bool { kind == "question" }
  public var question: Question? { questions.indices.contains(index) ? questions[index] : nil }
  public var multi: Bool { question?.multiSelect == true }

  init(session: String, prompt p: Prompt, under anchor: Box, width: Double, time: Int) {
    self.session = session; self.prompt = p.id; kind = p.kind
    title = p.text; detail = p.detail ?? ""
    questions = p.kind == "question" ? (p.questions ?? []) : []
    plan = p.plan ?? ""
    deal(under: anchor, width: width, time: time)
  }

  private func items() -> [SpreadCard] {
    let blank = Box(x: 0, y: 0, w: Spread.cardW, h: Spread.cardH)
    switch kind {
    case "question":
      guard let q = question else { return [] }
      var out = q.options.map { SpreadCard(kind: .option($0.label), title: $0.label, detail: Spread.clean($0.description ?? ""), box: blank) }
      if multi { out.append(SpreadCard(kind: .done, title: "Done ✓", detail: "Send the picked options", box: blank)) }
      return out
    case "plan":
      return [SpreadCard(kind: .allow, title: "Approve plan", detail: "Claude starts working on it", box: blank),
              SpreadCard(kind: .deny, title: "Keep planning", detail: "Right-click to say what should change", box: blank)]
    case "input":
      return [SpreadCard(kind: .allow, title: "Dismiss", detail: "Put it away; answer in the terminal when you're ready", box: blank)]
    default:
      return [SpreadCard(kind: .allow, title: "Allow", detail: "Let Claude do this", box: blank),
              SpreadCard(kind: .deny, title: "Deny", detail: "Right-click to tell Claude why", box: blank)]
    }
  }

  /// Lays the cards in rows below the anchor (above it if there's no room), centred on it and
  /// kept on the stage. A plan gets its sheet first, with the cards under it.
  mutating func deal(under anchor: Box, width: Double, time: Int) {
    var list = items()
    let perRow = max(1, min(list.count, Int((width - 40 + Spread.gap) / (Spread.cardW + Spread.gap))))
    let rows = (list.count + perRow - 1) / perRow
    let blockH = Double(rows) * Spread.cardH + Double(rows - 1) * Spread.gap
    // 80 units above for the banner; a plan's sheet sits between the banner and the cards.
    var top = anchor.y + anchor.h + 80
    if kind == "plan" {
      let w = min(780, width - 40), x = min(max(20, anchor.x + anchor.w / 2 - w / 2), width - 20 - w)
      let h = max(160, min(420, 890 - blockH - Spread.gap - top))
      sheet = Box(x: x, y: top, w: w, h: h)
      top += h + Spread.gap
    } else if top + blockH > 890 { top = max(70, anchor.y - 20 - blockH) }
    for i in list.indices {
      let row = i / perRow, col = i % perRow
      let inRow = min(perRow, list.count - row * perRow)
      let rowW = Double(inRow) * Spread.cardW + Double(inRow - 1) * Spread.gap
      let left = min(max(20, anchor.x + anchor.w / 2 - rowW / 2), width - 20 - rowW)
      list[i].box = Box(x: left + Double(col) * (Spread.cardW + Spread.gap), y: top + Double(row) * (Spread.cardH + Spread.gap), w: Spread.cardW, h: Spread.cardH)
    }
    cards = list; picked = []; dealtAt = time; sheetScroll = 0
  }

  public func card(at p: Point) -> Int? { cards.firstIndex { $0.box.contains(p) } }

  /// What the cards are dealt under: the prompt box, stretched down past the character's name label.
  static func anchor(_ c: Character, _ box: Box) -> Box { Box(x: box.x, y: box.y, w: box.w, h: max(box.h, c.y + 108 - box.y)) }

  /// Option text without other plugins' bookkeeping markers such as "[work: 3 calls, 10K]".
  public static func clean(_ s: String) -> String {
    s.replacingOccurrences(of: #"\s*\[work:[^\]]*\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
  }

  /// Where the banner is drawn: just above the sheet or the first row of cards.
  public var bannerY: Double { (sheet?.y ?? cards.map(\.box.y).min() ?? 0) - 18 }

  enum Step { case next, toggled, answered(decision: String) }
  /// Picks card `i`, with an optional note.
  mutating func choose(_ i: Int, note rawNote: String?) -> Step {
    let note = rawNote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    switch cards[i].kind {
    case .allow: return .answered(decision: "allow")
    case .deny:
      if let note { notes["message"] = note }
      return .answered(decision: "deny")
    case .option(let label):
      guard let q = question else { return .answered(decision: "allow") }
      if let note { notes[q.question] = notes[q.question].map { $0 + "; " + note } ?? note }
      if multi {
        if picked.contains(label) && rawNote == nil { picked.remove(label) } else { picked.insert(label) }
        return .toggled
      }
      answers[q.question] = label
    case .done:
      guard let q = question else { return .answered(decision: "allow") }
      answers[q.question] = q.options.map(\.label).filter { picked.contains($0) }.joined(separator: ", ")
    }
    if index + 1 < questions.count { index += 1; return .next }
    return .answered(decision: "allow")
  }

  /// What goes to Claude for a question: the picks, with any note woven in so it is read whatever the tool shows.
  public var finalAnswers: [String: String] {
    var out = answers
    for (q, n) in notes { out[q] = (out[q].map { $0.isEmpty ? "" : $0 + " — " } ?? "") + "note: " + n }
    return out
  }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

extension Stage {
  /// Deals the cards for a character's prompt. False if nothing is waiting there.
  @discardableResult
  public func openSpread(_ c: Character) -> Bool {
    guard let p = c.prompt, !c.answered, let box = c.box else { return false }
    if p.kind == "question" && (p.questions ?? []).isEmpty { return false }
    spread = Spread(session: c.id, prompt: p, under: Spread.anchor(c, box), width: width, time: time)
    onSound(.toggle(on: true))
    return true
  }
  public func closeSpread() { if spread != nil { spread = nil; onSound(.toggle(on: false)) } }

  /// Mouse wheel over the plan sheet.
  public func scrollSheet(lines: Int) { guard var s = spread, s.sheet != nil else { return }; s.sheetScroll = max(0, s.sheetScroll + lines); spread = s }

  // MARK: notes on the back of a card

  /// Right-click: flip card `i` over to type a note on its back. Cards that take no note just act.
  public func beginNote(_ i: Int) {
    guard var s = spread, s.cards.indices.contains(i) else { return }
    if !s.cards[i].takesNote { chooseCard(i); return }
    s.note = Spread.Note(card: i, text: "", since: time)
    spread = s
    onSound(.toggle(on: true))
  }
  public var noting: Bool { spread?.note != nil }
  public func typeNote(_ text: String) {
    guard var s = spread, var n = s.note else { return }
    let clean = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").filter { !$0.isASCII || $0.asciiValue! >= 32 }
    n.text = String((n.text + clean).prefix(Spread.noteLimit))
    s.note = n; spread = s
  }
  public func deleteNoteCharacter() {
    guard var s = spread, var n = s.note, !n.text.isEmpty else { return }
    n.text.removeLast(); s.note = n; spread = s
  }
  /// Return: pick the flipped card with what's written on its back.
  public func submitNote() {
    guard var s = spread, let n = s.note else { return }
    s.note = nil; spread = s
    chooseCard(n.card, note: n.text)
  }
  /// Esc: flip the card back; nothing is picked.
  public func cancelNote() {
    guard var s = spread, s.note != nil else { return }
    s.note = nil; spread = s
    onSound(.toggle(on: false))
  }

  /// Left-click (note nil) or right-click-then-note on card `i`.
  public func chooseCard(_ i: Int, note: String? = nil) {
    guard var s = spread, s.cards.indices.contains(i), let c = characters[s.session], !c.answered, c.prompt?.id == s.prompt else { spread = nil; return }
    let card = s.cards[i]
    let deny = card.kind == .deny
    burst(card.box.x + card.box.w / 2, card.box.y + card.box.h / 2, deny ? "✕" : note == nil ? "✓" : "✎", deny ? .red : .lime, 6)
    switch s.choose(i, note: note) {
    case .toggled: spread = s; onSound(.toggle(on: true))
    case .next: if let b = c.box { s.deal(under: Spread.anchor(c, b), width: width, time: time) }; spread = s; onSound(.ping(3))
    case .answered(let decision):
      spread = nil
      c.answered = true; c.decision = decision
      let label = s.kind == "question" ? "ANSWERED" : s.kind == "input" ? "LATER" : decision == "allow" ? "APPROVED" : "DENIED"
      c.stamp = StampMark(text: label, approve: decision == "allow", life: 60, max: 60)
      onSound(decision == "allow" ? .approve : .thunk(light: false))
      let message = s.notes["message"]
      onAnswer(Answer(session: c.id, prompt: s.prompt, decision: decision, source: "cards",
                      answers: s.isQuestion ? s.finalAnswers : nil,
                      notes: s.isQuestion ? (s.notes.isEmpty ? nil : s.notes) : nil,
                      message: message))
    }
  }
}
