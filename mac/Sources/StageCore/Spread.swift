// Answering a question by cards: click a question box and one card per option is dealt out under it.
// Left-click a card to pick it; right-click to pick it with a note. With several questions they come
// one at a time; the answer goes out after the last. Multi-select questions get a Done card.
import Foundation

public struct SpreadCard: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case option(String), done }
  public let kind: Kind
  public let title: String
  public let detail: String
  public var box: Box
}

public struct Spread: Sendable {
  public let session: String
  public let prompt: String
  public let questions: [Question]
  public private(set) var index = 0
  public private(set) var answers: [String: String] = [:]
  public private(set) var notes: [String: String] = [:]
  /// Picked labels for the current multi-select question.
  public private(set) var picked: Set<String> = []
  public private(set) var cards: [SpreadCard] = []
  public private(set) var dealtAt = 0
  /// A card flipped over to take a note (right-click): which card, what's typed, when it flipped.
  public struct Note: Equatable, Sendable { public let card: Int; public var text: String; public let since: Int }
  public internal(set) var note: Note? = nil
  public static let noteLimit = 400

  public static let cardW = 230.0, cardH = 128.0, gap = 18.0

  public var question: Question { questions[index] }
  public var multi: Bool { question.multiSelect == true }

  init(session: String, prompt: String, questions: [Question], under anchor: Box, width: Double, time: Int) {
    self.session = session; self.prompt = prompt; self.questions = questions
    deal(under: anchor, width: width, time: time)
  }

  /// Lays the current question's cards in rows below the anchor (above it if there's no room),
  /// centred on it and kept on the stage.
  mutating func deal(under anchor: Box, width: Double, time: Int) {
    var items = question.options.map { SpreadCard(kind: .option($0.label), title: $0.label, detail: Spread.clean($0.description ?? ""), box: Box(x: 0, y: 0, w: Spread.cardW, h: Spread.cardH)) }
    if multi { items.append(SpreadCard(kind: .done, title: "Done ✓", detail: "Send the picked options", box: Box(x: 0, y: 0, w: Spread.cardW, h: Spread.cardH))) }
    let perRow = max(1, min(items.count, Int((width - 40 + Spread.gap) / (Spread.cardW + Spread.gap))))
    let rows = (items.count + perRow - 1) / perRow
    let blockH = Double(rows) * Spread.cardH + Double(rows - 1) * Spread.gap
    // 60 units of room above the cards for the question banner.
    var top = anchor.y + anchor.h + 80
    if top + blockH > 890 { top = max(70, anchor.y - 20 - blockH) }
    for (i, _) in items.enumerated() {
      let row = i / perRow, col = i % perRow
      let inRow = min(perRow, items.count - row * perRow)
      let rowW = Double(inRow) * Spread.cardW + Double(inRow - 1) * Spread.gap
      let left = min(max(20, anchor.x + anchor.w / 2 - rowW / 2), width - 20 - rowW)
      items[i].box = Box(x: left + Double(col) * (Spread.cardW + Spread.gap), y: top + Double(row) * (Spread.cardH + Spread.gap), w: Spread.cardW, h: Spread.cardH)
    }
    cards = items; picked = []; dealtAt = time
  }

  public func card(at p: Point) -> Int? { cards.firstIndex { $0.box.contains(p) } }

  /// What the cards are dealt under: the prompt box, stretched down past the character's name label.
  static func anchor(_ c: Character, _ box: Box) -> Box { Box(x: box.x, y: box.y, w: box.w, h: max(box.h, c.y + 108 - box.y)) }

  /// Option text without other plugins' bookkeeping markers such as "[work: 3 calls, 10K]".
  public static func clean(_ s: String) -> String {
    s.replacingOccurrences(of: #"\s*\[work:[^\]]*\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
  }

  /// Where the question text is drawn: just above the first row of cards.
  public var bannerY: Double { (cards.map(\.box.y).min() ?? 0) - 18 }

  enum Step { case next, done, toggled }
  /// Picks card `i`, with an optional note. Returns whether the spread moved on or finished.
  mutating func choose(_ i: Int, note: String?) -> Step {
    let q = question.question
    if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { notes[q] = notes[q].map { $0 + "; " + n } ?? n }
    switch cards[i].kind {
    case .option(let label) where multi:
      if picked.contains(label) && note == nil { picked.remove(label) } else { picked.insert(label) }
      return .toggled
    case .option(let label):
      answers[q] = label
    case .done:
      answers[q] = question.options.map(\.label).filter { picked.contains($0) }.joined(separator: ", ")
    }
    if index + 1 < questions.count { index += 1; return .next }
    return .done
  }

  /// What goes to Claude: the picks, with any note woven in so it is read whatever the tool shows.
  public var finalAnswers: [String: String] {
    var out = answers
    for (q, n) in notes { out[q] = (out[q].map { $0.isEmpty ? "" : $0 + " — " } ?? "") + "note: " + n }
    return out
  }
}

extension Stage {
  /// Deals the cards for a character's question. False if it isn't a question waiting for you.
  @discardableResult
  public func openSpread(_ c: Character) -> Bool {
    guard let p = c.prompt, p.kind == "question", !c.answered, let qs = p.questions, !qs.isEmpty, let box = c.box else { return false }
    spread = Spread(session: c.id, prompt: p.id, questions: qs, under: Spread.anchor(c, box), width: width, time: time)
    onSound(.toggle(on: true))
    return true
  }
  public func closeSpread() { if spread != nil { spread = nil; onSound(.toggle(on: false)) } }

  // MARK: notes on the back of a card

  /// Right-click: flip card `i` over to type a note on its back. The Done card just sends.
  public func beginNote(_ i: Int) {
    guard var s = spread, s.cards.indices.contains(i) else { return }
    if s.cards[i].kind == .done { chooseCard(i); return }
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
    burst(card.box.x + card.box.w / 2, card.box.y + card.box.h / 2, note == nil ? "✓" : "✎", .lime, 6)
    switch s.choose(i, note: note) {
    case .toggled: spread = s; onSound(.toggle(on: true))
    case .next: if let b = c.box { s.deal(under: b, width: width, time: time) }; spread = s; onSound(.ping(3))
    case .done:
      spread = nil
      c.answered = true; c.decision = "allow"
      c.stamp = StampMark(text: "ANSWERED", approve: true, life: 60, max: 60)
      onSound(.approve)
      onAnswer(Answer(session: c.id, prompt: s.prompt, decision: "allow", source: "cards", answers: s.finalAnswers, notes: s.notes.isEmpty ? nil : s.notes))
    }
  }
}
