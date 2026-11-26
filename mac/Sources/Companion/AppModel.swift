// Shared app state: sessions from the server, the armed tools, and the stage they drive.
import AppKit
import SwiftUI
import StageCore

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var sessions = Sessions()
  @Published private(set) var tools = Tools()
  @Published var connected = false
  /// The session last picked from the sessions menu (shown with a check mark there).
  @Published var selectedSession: String?
  @Published var logLines: [LogLine] = []
  let stage = Stage(width: 1600)
  let server = Server()
  let audio = Audio()
  private(set) var logShownFor: String?
  private var logPanel: NSPanel?

  init() {
    stage.onSound = { [weak self] s in self?.audio.play(s) }
    stage.onToolsChanged = { [weak self] tools in self?.toolsChanged(to: tools) }
    stage.onAnswer = { [weak self] a in self?.answer(a) }
    server.onConnected = { [weak self] ok in self?.connected = ok }
    server.onEvent = { [weak self] e in self?.apply(e) }
  }

  func start() {
    server.start()
    pollRemarc(); Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollRemarc() } }
  }

  /// The inbox as the server sees it: whether a Remarc session is linked, live or batch, and how many comments wait.
  struct RemarcState: Equatable { var linked = false; var batch = false; var pending = 0 }
  @Published var remarc = RemarcState()
  private func pollRemarc() {
    server.get("remarc") { [weak self] data in
      guard let j = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
      let next = RemarcState(linked: j["linked"] as? Bool ?? false, batch: (j["mode"] as? String) == "batch", pending: j["pending"] as? Int ?? 0)
      if next != self?.remarc { self?.remarc = next }
    }
  }
  func setRemarcBatch(_ batch: Bool) { remarc.batch = batch; server.post("remarc/mode", ["mode": batch ? "batch" : "live"]) }
  func sendRemarcBatch() { server.post("remarc/send", [:]) { [weak self] _, _ in self?.remarc.pending = 0 } }

  func apply(_ e: ServerEvent) {
    sessions.apply(e)
    switch e {
    case .greet(let id): if let s = sessions[id] { stage.greet(s) }
    case .log(let id, let lines) where id == logShownFor: logLines.append(contentsOf: lines); if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    default: break
    }
    stage.sync(sessions.all)
  }

  /// An answer clears the prompt here at once, then goes to the server, which replies to Claude.
  func answer(_ a: Answer) {
    sessions.answered(a.session, prompt: a.prompt)
    stage.sync(sessions.all)
    server.answer(a)
  }

  // MARK: iPhone questions

  /// Unanswered questions, as cards for the phone. Plans and permissions stay with the whip and stamp.
  func phoneQuestions() -> [PhoneWhipWire.QuestionCard] {
    sessions.all.compactMap { s in
      guard let p = s.prompt, p.kind == "question", let qs = p.questions, !qs.isEmpty,
            stage.characters[s.id]?.answered != true else { return nil }
      return .init(session: s.id, prompt: p.id, folder: s.folder ?? "session", title: s.title ?? "", cwd: s.cwd,
                   questions: qs.map { q in
                     .init(question: q.question, header: q.header,
                           options: q.options.map { .init(label: $0.label, description: $0.description) },
                           multiSelect: q.multiSelect == true)
                   })
    }
  }

  /// Applies the phone's answer the way a card pick would. Validates against the live prompt so a stale or
  /// malformed request cannot answer something else.
  func phoneAnswer(session id: String, prompt: String, decision: String, answers: [String: String]?,
                   notes: [String: String]?) -> PhoneWhipWire.DictationReply {
    guard let p = sessions[id]?.prompt, p.id == prompt, p.kind == "question", let qs = p.questions else {
      return .init(answered: false)
    }
    var picked: [String: String]?
    if decision == "allow" {
      guard let answers else { return .init(error: "Pick an answer for every question.") }
      var clean: [String: String] = [:]
      for q in qs {
        let labels = (answers[q.question] ?? "").components(separatedBy: ", ")
        let valid = q.options.map(\.label).filter { labels.contains($0) }
        guard !valid.isEmpty, q.multiSelect == true || valid.count == 1 else {
          return .init(error: "Pick an answer for every question.")
        }
        clean[q.question] = valid.joined(separator: ", ")
      }
      picked = clean
    } else if decision != "deny" { return .init(error: "Unknown decision.") }
    let questions = Set(qs.map(\.question))
    let cleanNotes = notes?.filter { questions.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    answer(Answer(session: id, prompt: prompt, decision: decision, source: "phone", answers: picked,
                  notes: decision == "allow" && cleanNotes?.isEmpty == false ? cleanNotes : nil))
    return .init(answered: true)
  }

  /// A whip from the phone at a session held on a prompt: allow the permission or plan, or pick the first
  /// option of every question, with a note that it has the go-ahead. answered false when nothing is waiting.
  func phoneGoAhead(session id: String) -> PhoneWhipWire.DictationReply {
    guard let p = sessions[id]?.prompt, p.kind != "input", stage.characters[id]?.answered != true else {
      return .init(answered: false)
    }
    let note = "The user cracked the whip from their phone: you have permission, go ahead and get it done."
    if p.kind == "question" {
      guard let qs = p.questions, !qs.isEmpty else { return .init(answered: false) }
      var picked: [String: String] = [:], notes: [String: String] = [:]
      for q in qs {
        guard let first = q.options.first else { return .init(error: "A question has no options to pick.") }
        picked[q.question] = first.label
        notes[q.question] = note
      }
      answer(Answer(session: id, prompt: p.id, decision: "allow", source: "phone", answers: picked, notes: notes))
    } else {
      answer(Answer(session: id, prompt: p.id, decision: "allow", source: "phone"))
    }
    return .init(answered: true)
  }

  // MARK: tools

  func toggle(_ key: WritableKeyPath<Tools, Bool>) {
    var t = stage.localTools
    t[keyPath: key].toggle()
    stage.setTools(t)
  }

  func disarm() {
    var t = stage.localTools
    t.whip = false; t.cannon = false; t.stamp = false
    stage.cancelPhoneWhip()
    stage.setTools(t)
  }

  /// Called when a mouse tool gets armed, so the overlay can take the keyboard (Esc, Space, Return).
  var onArmed: () -> Void = {}
  private func toolsChanged(to t: Tools) {
    let was = tools.takesMouse
    tools = t; audio.muted = t.muted
    if t.inHand { hideLog() }
    if t.takesMouse && !was { onArmed() }
  }

  /// A click on a prompt box with no tool armed deals its cards on the stage.
  func clicked(at p: Point) {
    guard let c = stage.pick(p), c.prompt != nil, !c.answered else { return }
    hideLog()
    stage.openSpread(c)
  }

  /// From the sessions menu: deal that session's cards (it walks back on stage if it had left).
  func open(session id: String, prompt: Prompt?) {
    if selectedSession != id { remarcResult = nil }
    selectedSession = id
    guard let prompt else { return }
    if stage.characters[id] == nil { stage.recall(prompt: prompt.id); stage.sync(sessions.all) }
    if let c = stage.characters[id] { stage.openSpread(c) }
  }

  /// Outcome of the last "Remarc" click: nil = none yet, else (ok, message).
  /// Pointer over the toolbar in its own SwiftUI coordinates; nil when outside.
  @Published var captionShown = false
  /// ⌥ is down while the pointer is over the toolbar; only then does the hover caption show.
  @Published var optionHeld = false
  var hideToolbar: (() -> Void)?
  @Published var toolbarPointer: CGPoint?
  @Published var remarcResult: (ok: Bool, message: String)?

  /// From the toolbar: starts a Remarc session for the selected Claude session, so its comments reach that session as prompts.
  func startRemarc() {
    // The server only links main sessions (never worktree ones). With none picked it links every main session.
    remarcResult = (true, "Starting…")
    server.post("remarc", selectedSession.map { ["session": $0] } ?? [:]) { [weak self] data, _ in
      let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let ok = j?["ok"] as? Bool ?? false
      self?.remarcResult = (ok, (ok ? j?["text"] : j?["error"]) as? String ?? "The companion server did not answer")
    }
  }

  /// Maps a stage box to screen coordinates (set by the overlay).
  var screenRect: (Box) -> NSRect = { _ in .zero }

  // MARK: hover log

  func showLog(for id: String, beside anchor: NSRect) {
    logShownFor = id; logLines = []
    let s = sessions[id]
    if logPanel == nil {
      let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isOpaque = false; p.backgroundColor = .clear; p.level = .statusBar; p.hasShadow = true
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.contentViewController = NSHostingController(rootView: LogPanel(model: self))
      logPanel = p
    }
    logTitle = (s?.folder ?? "session", s?.title ?? "")
    // Left of the anchor when there is room, else right of it; vertically centred on it.
    let screen = NSScreen.main?.visibleFrame ?? .zero, w: CGFloat = 460, h: CGFloat = min(420, screen.height - 20)
    var x = anchor.minX - 12 - w
    if x < screen.minX + 8 { x = min(anchor.maxX + 12, screen.maxX - w - 8) }
    let y = max(screen.minY + 8, min(screen.maxY - h - 8, anchor.midY - h / 2))
    logPanel?.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    logPanel?.orderFrontRegardless()
    server.log(id) { [weak self] lines in if self?.logShownFor == id { self?.logLines = lines } }
  }
  @Published var logTitle = ("", "")
  func hideLog() { logShownFor = nil; logPanel?.orderOut(nil) }
  func pointerInLog() -> Bool { logPanel?.isVisible == true && logPanel!.frame.contains(NSEvent.mouseLocation) }
}
