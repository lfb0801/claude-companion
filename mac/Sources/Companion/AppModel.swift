// Shared app state: sessions from the server, the armed tools, and the stage they drive.
import AppKit
import SwiftUI
import StageCore

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var sessions = Sessions()
  @Published private(set) var tools = Tools()
  @Published var connected = false
  @Published var logLines: [LogLine] = []
  let stage = Stage(width: 1600)
  let server = Server()
  let audio = Audio()
  private(set) var logShownFor: String?
  private var card: NSPanel?, cardFor: (session: String, prompt: String)?
  private var logPanel: NSPanel?

  init() {
    stage.onSound = { [weak self] s in self?.audio.play(s) }
    stage.onAnswer = { [weak self] a in self?.answer(a) }
    server.onConnected = { [weak self] ok in self?.connected = ok }
    server.onEvent = { [weak self] e in self?.apply(e) }
  }

  func start() { server.start() }

  func apply(_ e: ServerEvent) {
    sessions.apply(e)
    switch e {
    case .greet(let id): if let s = sessions[id] { stage.greet(s) }
    case .log(let id, let lines) where id == logShownFor: logLines.append(contentsOf: lines); if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    default: break
    }
    stage.sync(sessions.all)
    if let c = cardFor, sessions[c.session]?.prompt?.id != c.prompt { closeCard() }
  }

  /// An answer clears the prompt here at once, then goes to the server, which replies to Claude.
  func answer(_ a: Answer) {
    sessions.answered(a.session, prompt: a.prompt)
    stage.sync(sessions.all)
    server.answer(a)
  }

  // MARK: tools

  func toggle(_ key: WritableKeyPath<Tools, Bool>) {
    var t = tools; t[keyPath: key].toggle(); set(t)
  }
  func disarm() { var t = tools; t.whip = false; t.cannon = false; set(t) }
  /// Called when a mouse tool gets armed, so the overlay can take the keyboard (Esc, Space, Return).
  var onArmed: () -> Void = {}
  private func set(_ t: Tools) {
    let was = tools.takesMouse
    tools = t; audio.muted = t.muted; stage.setTools(t)
    if t.inHand { hideLog() }
    if t.takesMouse && !was { onArmed() }
  }

  /// A click on the stage with no tool armed: the prompt box opens its card.
  func clicked(at p: Point) {
    guard let c = stage.pick(p), let prompt = c.prompt, !c.answered else { return }
    openCard(session: c.id, prompt: prompt)
  }

  // MARK: prompt card

  func openCard(session id: String, prompt: Prompt) {
    closeCard()
    let s = sessions[id]
    let view = PromptCard(prompt: prompt, folder: s?.folder ?? "session", title: s?.title ?? "") { [weak self] decision, answers in
      guard let self else { return }
      if let c = self.stage.characters[id], !c.answered { c.answered = true; c.decision = decision }
      self.answer(Answer(session: id, prompt: prompt.id, decision: decision, source: "card", answers: answers))
      self.closeCard()
    } cancel: { [weak self] in self?.closeCard() }
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
    panel.level = .modalPanel; panel.isReleasedWhenClosed = false
    panel.contentViewController = NSHostingController(rootView: view)
    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    card = panel; cardFor = (id, prompt.id)
  }
  func closeCard() { card?.close(); card = nil; cardFor = nil }

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
