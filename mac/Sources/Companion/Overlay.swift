// The desktop overlay: a transparent panel over the whole screen, on every Space, above other windows.
// Clicks pass through to your apps except on a character or its prompt, or while a mouse tool is armed.
import AppKit
import StageCore

final class OverlayPanel: NSPanel {
  init(screen: NSScreen) {
    super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false; backgroundColor = .clear; hasShadow = false
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    ignoresMouseEvents = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
  }
  // Becomes key only while a tool is armed, so Esc / Space / W... reach the stage.
  var wantsKey = false
  override var canBecomeKey: Bool { wantsKey }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class StageView: NSView {
  let model: AppModel
  let sprites = Sprites()
  init(model: AppModel) { self.model = model; super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = .clear }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Stage units are 900 high; the stage is as wide as the screen at that scale.
  var scale: CGFloat { max(bounds.height, 1) / 900 }
  func toStage(_ p: NSPoint) -> Point { Point(p.x / scale, p.y / scale) }

  override func draw(_ dirty: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.clear(bounds)
    ctx.saveGState()
    let shake = model.stage.shake
    ctx.translateBy(x: shake > 0 ? .random(in: -shake...shake) * scale : 0, y: shake > 0 ? .random(in: -shake...shake) * scale : 0)
    ctx.scaleBy(x: scale, y: scale)
    Renderer(ctx: ctx, stage: model.stage, sprites: sprites).draw()
    ctx.restoreGState()
  }

  private func point(_ e: NSEvent) -> Point { toStage(convert(e.locationInWindow, from: nil)) }

  override func mouseDown(with e: NSEvent) {
    let p = point(e); model.stage.mouse = p
    // Answer cards out: a card picks, anywhere else puts them away.
    // While a card is flipped for a note, a click elsewhere just flips it back.
    let t = model.stage.localTools
    if let s = model.stage.spread {
      if let n = s.note { if s.card(at: p) != n.card { model.stage.cancelNote() }; return }
      // The stamp (or the whip's handle) slammed on the cards requests changes.
      if t.clickStamps && model.stage.onSpread(p) { model.stage.stampSpread(at: p); return }
      if let i = s.card(at: p) { model.stage.chooseCard(i) } else { model.stage.closeSpread() }
      if !t.clickStamps { return }
    }
    if t.cannon { model.stage.firing = true; return }
    // The stamp, or a click with the whip in hand (the back of its handle): denies what's under it.
    if t.clickStamps { model.stage.stamp(at: p); return }
    model.clicked(at: p)
  }
  override func mouseUp(with e: NSEvent) { model.stage.firing = false }
  /// The mouse wheel scrolls a plan sheet.
  override func scrollWheel(with e: NSEvent) {
    guard let sheet = model.stage.spread?.sheet, sheet.contains(point(e)) else { return }
    let lines = Int((-e.scrollingDeltaY / (e.hasPreciseScrollingDeltas ? 17 : 1)).rounded())
    if lines != 0 { model.stage.scrollSheet(lines: lines) }
  }
  override func rightMouseDown(with e: NSEvent) {
    let p = point(e)
    // Right-click a card: it flips over and you write a note on its back.
    if let s = model.stage.spread {
      if s.note != nil { model.stage.cancelNote() }
      if let i = s.card(at: p) { model.stage.beginNote(i) } else if s.note == nil { model.stage.closeSpread() }
      return
    }
    model.disarm()
  }

  // Writing on a flipped card: AppKit's own key handling, so accents and dead keys work.
  override func insertText(_ s: Any) { model.stage.typeNote((s as? NSAttributedString)?.string ?? (s as? String) ?? "") }
  override func deleteBackward(_ sender: Any?) { model.stage.deleteNoteCharacter() }
  override func deleteWordBackward(_ sender: Any?) { model.stage.deleteNoteWord() }               // ⌥⌫
  override func deleteToBeginningOfLine(_ sender: Any?) { model.stage.clearNote() }              // ⌘⌫
  override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) { model.stage.deleteNoteCharacter() }
  override func insertNewline(_ sender: Any?) { model.stage.submitNote() }
  override func cancelOperation(_ sender: Any?) { model.stage.cancelNote() }
  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    if model.stage.noting, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "v" {
      model.stage.typeNote(NSPasteboard.general.string(forType: .string) ?? ""); return true
    }
    return super.performKeyEquivalent(with: e)
  }

  override func keyDown(with e: NSEvent) {
    if model.stage.noting { interpretKeyEvents([e]); return }
    switch e.keyCode {
    case 53: if model.stage.spread != nil { model.stage.closeSpread() } else { model.disarm() }  // Esc
    case 49: if model.tools.cannon { model.stage.firing = true } // Space
    default:
      switch e.charactersIgnoringModifiers?.lowercased() {
      case "w": model.toggle(\.whip); case "g": model.toggle(\.cannon); case "d": model.toggle(\.stamp)
      case "h": model.toggle(\.intern)
      default: super.keyDown(with: e)
      }
    }
  }
  override func keyUp(with e: NSEvent) { if e.keyCode == 49 { model.stage.firing = false } }
}

/// Runs the stage at 60 frames a second and keeps the overlay's click-through in step with it.
@MainActor
final class OverlayController {
  let model: AppModel
  let panel: OverlayPanel
  let view: StageView
  private var timer: Timer?
  private var hoverId: String?, hoverSince = 0.0, hoverLostAt: Double? = nil

  init(model: AppModel) {
    self.model = model
    let screen = NSScreen.main ?? NSScreen.screens[0]
    panel = OverlayPanel(screen: screen)
    view = StageView(model: model)
    panel.contentView = view
    panel.setFrame(screen.frame, display: false)
    panel.orderFrontRegardless()
    relayout()
    listenForSnapshots()
    model.screenRect = { [weak self] b in self?.screenRect(b) ?? .zero }
    model.onArmed = { [weak self] in
      guard let self else { return }
      self.panel.wantsKey = true
      self.panel.ignoresMouseEvents = false
      self.panel.makeKeyAndOrderFront(nil)
      self.panel.makeFirstResponder(self.view)
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.fitScreen() } }
    timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
    RunLoop.main.add(timer!, forMode: .common)
  }

  /// Writes what the overlay is drawing to ~/Library/Logs/Companion/snapshot.png, over a dark backdrop
  /// so it reads on its own. Triggered by `kill -USR1 <pid>`; needs no screen-recording permission.
  func snapshot() {
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let g = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    let flipped = NSGraphicsContext(cgContext: g.cgContext, flipped: true)
    NSGraphicsContext.current = flipped
    let ctx = flipped.cgContext
    ctx.translateBy(x: 0, y: b.height); ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(NSColor(hex: 0x2a2d33).cgColor); ctx.fill(b)
    ctx.scaleBy(x: view.scale, y: view.scale)
    Renderer(ctx: ctx, stage: model.stage, sprites: view.sprites).draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Companion")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? png.write(to: dir.appendingPathComponent("snapshot.png"))
  }
  private var signalSources: [DispatchSourceSignal] = []
  /// Test hooks: `kill -USR1` writes a snapshot; `kill -USR2` "clicks" the first waiting prompt
  /// (deals a question's cards, or opens another prompt's card).
  func listenForSnapshots() {
    for (sig, act) in [(SIGUSR1, { [weak self] in self?.snapshot() }), (SIGUSR2, { [weak self] in
      guard let self, let c = self.model.stage.targets.first, let p = c.prompt else { return }
      self.model.open(session: c.id, prompt: p)
    })] as [(Int32, @MainActor () -> Void)] {
      signal(sig, SIG_IGN)
      let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      s.setEventHandler { MainActor.assumeIsolated { act() } }
      s.resume(); signalSources.append(s)
    }
  }

  private func fitScreen() { panel.setFrame((NSScreen.main ?? NSScreen.screens[0]).frame, display: true); relayout() }
  private func relayout() { model.stage.relayout(width: Double(view.bounds.width / view.scale)) }

  /// Stage coordinates of the cursor, read globally so the whip follows it over other apps too.
  private var cursor: Point {
    let m = NSEvent.mouseLocation, f = panel.frame
    return view.toStage(NSPoint(x: m.x - f.minX, y: f.maxY - m.y))
  }
  func armFromPhone() {
    if panel.frame.contains(NSEvent.mouseLocation) { model.stage.mouse = cursor }
    model.stage.holdPhoneWhip()
  }

  func crackFromPhone(onSnap: @escaping () -> Void) -> Bool {
    guard panel.frame.contains(NSEvent.mouseLocation) else { return false }
    model.stage.mouse = cursor
    return model.stage.flickPhoneWhip(onSnap: onSnap)
  }

  func stampFromPhone() -> Bool {
    guard panel.frame.contains(NSEvent.mouseLocation) else { return false }
    return model.stage.stampFromPhone(at: cursor)
  }

  func screenRect(_ b: Box) -> NSRect {
    let s = view.scale, f = panel.frame
    return NSRect(x: f.minX + b.x * s, y: f.maxY - (b.y + b.h) * s, width: b.w * s, height: b.h * s)
  }

  private func frame() {
    let stage = model.stage
    stage.mouse = cursor
    stage.tick()
    // Click-through unless the pointer is on a character or a mouse tool is armed.
    // While answer cards are out the overlay takes every click (outside a card puts them away) and Esc.
    let cards = stage.spread != nil
    let armed = model.tools.takesMouse, over = stage.pick(stage.mouse)
    let interactive = armed || cards || over != nil
    if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    panel.wantsKey = armed || cards
    if cards && !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view) }
    // No hover log while a tool is in hand or a prompt card is open (it would cover the card).
    hover(model.tools.inHand || stage.spread != nil ? nil : over)
    view.needsDisplay = true
  }

  /// The hover log opens after a short dwell on a character and closes shortly after the pointer leaves.
  private func hover(_ c: Character?) {
    let now = CACurrentMediaTime()
    if let c {
      hoverLostAt = nil
      if c.id != hoverId { hoverId = c.id; hoverSince = now; model.hideLog() }
      else if now - hoverSince > 0.35 && model.logShownFor != c.id {
        let anchor = screenRect(c.box ?? Box(x: c.x - c.r, y: c.y - c.r, w: c.r * 2, h: c.r * 2))
        model.showLog(for: c.id, beside: anchor)
      }
    } else if hoverId != nil {
      if model.pointerInLog() { hoverLostAt = nil; return }
      if hoverLostAt == nil { hoverLostAt = now }
      if now - (hoverLostAt ?? now) > 0.25 { hoverId = nil; hoverLostAt = nil; model.hideLog() }
    }
  }
}
