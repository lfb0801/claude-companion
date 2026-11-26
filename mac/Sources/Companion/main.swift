// Claude Code Companion for macOS: a menu bar app with a desktop overlay.
import AppKit
import SwiftUI
import Carbon.HIToolbox
import SystemConfiguration

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var model: AppModel!
  var overlay: OverlayController!
  var toolbar: NSPanel!
  var status: NSStatusItem!
  private var phoneWhip: PhoneWhipReceiver!
  private var phoneApproval: NSPanel?
  private var pendingPhoneApproval: (number: String, decide: (Bool) -> Void)?
  private let phoneWhipDisabledKey = "PhoneWhipDisabled"

  func applicationDidFinishLaunching(_ n: Notification) {
    MainActor.assumeIsolated {
      model = AppModel()
      overlay = OverlayController(model: model)
      phoneWhip = PhoneWhipReceiver(trust: PhoneWhipTrust())
      phoneWhip.onApproval = { [weak self] number, decide in self?.showPhoneApproval(number, decide: decide) }
      phoneWhip.onApprovalEnded = { [weak self] in self?.dismissPhoneApproval() }
      phoneWhip.onArm = { [weak self] in self?.overlay.armFromPhone() }
      phoneWhip.onDrop = { [weak self] in self?.model.stage.releasePhoneWhip() }
      phoneWhip.onFlick = { [weak self] onSnap in self?.overlay.crackFromPhone(onSnap: onSnap) ?? false }
      phoneWhip.onStamp = { [weak self] in self?.overlay.stampFromPhone() ?? false }
      phoneWhip.onDictation = { [weak self] request, done in self?.handlePhone(request, done) }
      toolbar = makeToolbar()
      model.hideToolbar = { [weak self] in self?.setToolbar(visible: false) }
      hotKeys = makeHotKeys()
      refused = HotKeys.register(hotKeys)
      status = makeStatusItem()
      model.start()
      if !UserDefaults.standard.bool(forKey: phoneWhipDisabledKey) { startPhoneWhip() }
    }
  }

  var toolbarHost: NSView!
  var toolbarTop: CGFloat = 0
  var toolbarObservers: [NSObjectProtocol] = []
  var hotKeys: [HotKey] = []
  var refused: [HotKey] = []

  /// ⌃⌥ + key, from any app.
  @MainActor private func makeHotKeys() -> [HotKey] {
    let m = model!
    return [
      HotKey(key: kVK_ANSI_W, letter: "W", title: "Whip") { m.toggle(\.whip) },
      HotKey(key: kVK_ANSI_G, letter: "G", title: "Cannon") { m.toggle(\.cannon) },
      HotKey(key: kVK_ANSI_D, letter: "D", title: "Stamp (request changes)") { m.toggle(\.stamp) },
      HotKey(key: kVK_ANSI_H, letter: "H", title: "Approval Intern") { m.toggle(\.intern) },
      HotKey(key: kVK_ANSI_X, letter: "X", title: "Put tools away") { m.disarm() },
      HotKey(key: kVK_ANSI_T, letter: "T", title: "Show or hide toolbar") { [weak self] in guard let self else { return }; setToolbar(visible: !toolbar.isVisible) },
    ]
  }

  func applicationWillTerminate(_ n: Notification) {
    MainActor.assumeIsolated { phoneWhip.stop(); model.server.stop() }
  }

  @MainActor private func makeToolbar() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
    p.level = .statusBar + 1
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.isMovableByWindowBackground = true
    p.hidesOnDeactivate = false
    let host = HoverHostingView(rootView: Toolbar(model: model)); host.model = model
    p.contentView = host
    toolbarHost = host
    p.setContentSize(host.fittingSize)
    // Remember where it was dragged to; first launch puts it at the top centre.
    if !p.setFrameUsingName("CompanionToolbar") {
      let s = NSScreen.main?.visibleFrame ?? .zero
      p.setFrameOrigin(NSPoint(x: s.midX - host.fittingSize.width / 2, y: s.maxY - host.fittingSize.height - 8))
    }
    p.setFrameAutosaveName("CompanionToolbar")
    toolbar = p
    keepToolbarTop(p)
    p.orderFrontRegardless()
    return p
  }

  /// Hides or shows the toolbar. A stale hover must not survive a hide, or it comes back with a caption it cannot explain.
  @MainActor func setToolbar(visible: Bool) {
    model.toolbarPointer = nil
    model.captionShown = false
    // Let SwiftUI drop the caption first, so the panel is the bar's size when it hides and when it returns.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
      if visible { toolbar.orderFrontRegardless() } else { toolbar.orderOut(nil) }
    }
  }

  /// The hosting view resizes the panel when the hover caption comes and goes, anchored at its bottom edge.
  /// Keep the top edge where the user put it instead.
  @MainActor private func keepToolbarTop(_ p: NSPanel) {
    let nc = NotificationCenter.default
    toolbarTop = p.frame.maxY
    toolbarObservers = [
      nc.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self, weak p] _ in
        MainActor.assumeIsolated { if let self, let p, abs(p.frame.maxY - self.toolbarTop) > 0.5, !self.resizing { self.toolbarTop = p.frame.maxY }
          self?.scheduleSnap() }
      },
      nc.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { [weak self, weak p] _ in
        MainActor.assumeIsolated {
          guard let self, let p, abs(p.frame.maxY - self.toolbarTop) > 0.5 else { return }
          self.resizing = true; p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: self.toolbarTop)); self.resizing = false
        }
      },
    ]
  }
  var resizing = false
  private var snapTimer: Timer?

  /// Once the toolbar stops moving and the button is up, pull it to a screen edge it is close to.
  @MainActor private func scheduleSnap() {
    snapTimer?.invalidate()
    snapTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let p = self.toolbar else { return }
        if NSEvent.pressedMouseButtons != 0 { self.scheduleSnap(); return }
        let area = (p.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let margin: CGFloat = 8, reach: CGFloat = 40
        var o = p.frame.origin
        let f = p.frame
        if abs(f.minX - area.minX) < reach { o.x = area.minX + margin } else if abs(area.maxX - f.maxX) < reach { o.x = area.maxX - f.width - margin }
        if abs(area.maxY - f.maxY) < reach { o.y = area.maxY - f.height - margin } else if abs(f.minY - area.minY) < reach { o.y = area.minY + margin }
        if o != f.origin { p.setFrameOrigin(o) }
      }
    }
  }

  @MainActor private func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // The companion itself, in colour, sized for the menu bar; falls back to a symbol if the art is missing.
    if let url = resource("happy-0", "png"), let art = NSImage(contentsOf: url) {
      art.size = NSSize(width: 22, height: 22 * art.size.height / art.size.width)
      art.accessibilityDescription = "Claude Companion"
      item.button?.image = art
    } else {
      item.button?.image = NSImage(systemSymbolName: "figure.wave", accessibilityDescription: "Claude Companion")
    }
    item.button?.imagePosition = .imageLeft
    let menu = NSMenu()
    menu.delegate = self
    let bar = NSMenuItem(title: "Show Toolbar", action: #selector(toggleToolbar), keyEquivalent: "t")
    bar.keyEquivalentModifierMask = [.control, .option]; bar.target = self; bar.tag = 1
    menu.addItem(bar)
    let whip = NSMenuItem(title: "Whip", action: #selector(toggleLocalWhip), keyEquivalent: "w")
    whip.keyEquivalentModifierMask = [.control, .option]; whip.target = self; whip.tag = 7
    menu.addItem(whip)
    let stamp = NSMenuItem(title: "Stamp (Deny or Request Changes)", action: #selector(toggleLocalStamp), keyEquivalent: "d")
    stamp.keyEquivalentModifierMask = [.control, .option]; stamp.target = self; stamp.tag = 8
    menu.addItem(stamp)
    let mute = NSMenuItem(title: "Mute Sound", action: #selector(toggleMute), keyEquivalent: "")
    mute.target = self; mute.tag = 2
    menu.addItem(mute)
    menu.addItem(.separator())
    let phone = NSMenuItem(title: "Turn Off iPhone Whip", action: #selector(togglePhoneWhip), keyEquivalent: "")
    phone.target = self; phone.tag = 3
    menu.addItem(phone)
    let reviewPhone = NSMenuItem(title: "No iPhone Pairing Request", action: #selector(reviewPhoneApproval), keyEquivalent: "")
    reviewPhone.target = self; reviewPhone.tag = 4
    menu.addItem(reviewPhone)
    let allowPhone = NSMenuItem(title: "Allow iPhone Whip", action: #selector(allowPhoneApproval), keyEquivalent: "")
    allowPhone.target = self; allowPhone.tag = 5; allowPhone.isHidden = true
    menu.addItem(allowPhone)
    let denyPhone = NSMenuItem(title: "Deny iPhone Pairing", action: #selector(denyPhoneApproval), keyEquivalent: "")
    denyPhone.target = self; denyPhone.tag = 6; denyPhone.isHidden = true
    menu.addItem(denyPhone)
    let forgetPhone = NSMenuItem(title: "Forget Paired iPhones", action: #selector(forgetPhones), keyEquivalent: "")
    forgetPhone.target = self
    menu.addItem(forgetPhone)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Claude Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu
    return item
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    MainActor.assumeIsolated {
      menu.item(withTag: 1)?.title = toolbar.isVisible ? "Hide Toolbar" : "Show Toolbar"
      menu.item(withTag: 2)?.state = model.tools.muted ? .on : .off
      menu.item(withTag: 3)?.title = phoneWhip.running ? "Turn Off iPhone Whip" : "Turn On iPhone Whip"
      menu.item(withTag: 7)?.state = model.stage.localTools.whip ? .on : .off
      menu.item(withTag: 8)?.state = model.stage.localTools.stamp ? .on : .off
      updatePhoneApprovalMenu()
    }
  }
  @MainActor @objc func toggleToolbar() { setToolbar(visible: !toolbar.isVisible) }
  @MainActor @objc private func toggleLocalWhip() { model.toggle(\.whip) }
  @MainActor @objc private func toggleLocalStamp() { model.toggle(\.stamp) }
  @MainActor @objc func toggleMute() { model.toggle(\.muted) }

  @MainActor @objc private func togglePhoneWhip() {
    let disable = phoneWhip.running
    UserDefaults.standard.set(disable, forKey: phoneWhipDisabledKey)
    if disable { phoneWhip.stop() } else { startPhoneWhip() }
  }

  /// Dictation goes to the inbox via the server; questions and answers use the live session state.
  @MainActor private func handlePhone(_ request: PhoneWhipWire.Dictation, _ done: @escaping (PhoneWhipWire.DictationReply) -> Void) {
    switch request {
    case .sessions, .send, .steer, .sideChat: model.server.dictation(request, done)
    case .questions: done(.init(cards: model.phoneQuestions()))
    case let .answer(session, prompt, decision, answers, notes):
      done(model.phoneAnswer(session: session, prompt: prompt, decision: decision, answers: answers, notes: notes))
    case let .goAhead(session):
      done(model.phoneGoAhead(session: session))
    }
  }

  @MainActor private func startPhoneWhip() {
    let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Claude Companion"
    do {
      try phoneWhip.start(name: name) { [weak self] error in
        self?.showPhoneWhipError("Couldn’t start iPhone Whip", detail: error.localizedDescription)
      }
    } catch { showPhoneWhipError("Couldn’t start iPhone Whip", detail: error.localizedDescription) }
  }

  @MainActor @objc private func forgetPhones() {
    if !phoneWhip.forgetPhones() {
      showPhoneWhipError("Couldn’t forget paired iPhones", detail: "Check access to your login keychain and try again.")
    }
  }

  @MainActor private func showPhoneApproval(_ number: String, decide: @escaping (Bool) -> Void) {
    pendingPhoneApproval = (number, decide)
    updatePhoneApprovalMenu()
    reviewPhoneApproval()
  }

  @MainActor private func updatePhoneApprovalMenu() {
    let number = pendingPhoneApproval?.number
    let menu = status.menu
    let review = menu?.item(withTag: 4)
    review?.title = number.map { "Review iPhone Pairing (\($0))…" } ?? "No iPhone Pairing Request"
    review?.action = number == nil ? nil : #selector(reviewPhoneApproval)
    review?.isHidden = !phoneWhip.running
    let allow = menu?.item(withTag: 5)
    allow?.title = number.map { "Allow iPhone Whip (\($0))" } ?? "Allow iPhone Whip"
    allow?.isHidden = number == nil
    menu?.item(withTag: 6)?.isHidden = number == nil
    if let button = status.button {
      button.attributedTitle = NSAttributedString(string: number == nil ? "" : " ●",
                                                   attributes: [.foregroundColor: NSColor.systemOrange])
      button.setAccessibilityLabel(number == nil ? "Claude Companion" : "Claude Companion, iPhone pairing pending")
    }
  }

  @MainActor @objc private func reviewPhoneApproval() {
    guard let pendingPhoneApproval else { return }
    if phoneApproval == nil {
      let content = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
        Text("Allow iPhone Whip?").font(.title2.bold())
        Text("Click Allow if this number matches Phone Whip on your iPhone.")
          .fixedSize(horizontal: false, vertical: true)
        Text(pendingPhoneApproval.number).font(.largeTitle.monospacedDigit().weight(.semibold))
        HStack {
          Spacer()
          Button("Deny") { [weak self] in self?.denyPhoneApproval() }.keyboardShortcut(.cancelAction)
          Button("Allow") { [weak self] in self?.allowPhoneApproval() }.buttonStyle(.borderedProminent)
        }
      }.padding(24).frame(width: 380))
      let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      panel.title = "iPhone Whip Pairing"
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.level = .statusBar + 2
      panel.contentView = content
      panel.setContentSize(content.fittingSize)
      phoneApproval = panel
    }
    guard let panel = phoneApproval else { return }
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
      let area = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
    } else { panel.center() }
    NSApp.activate()
    panel.orderFrontRegardless()
    panel.makeKeyAndOrderFront(nil)
  }

  @MainActor @objc private func allowPhoneApproval() { pendingPhoneApproval?.decide(true) }
  @MainActor @objc private func denyPhoneApproval() { pendingPhoneApproval?.decide(false) }

  @MainActor private func dismissPhoneApproval() {
    pendingPhoneApproval = nil
    phoneApproval?.close()
    phoneApproval = nil
    updatePhoneApprovalMenu()
  }

  @MainActor private func showPhoneWhipError(_ message: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    NSApp.activate()
    alert.runModal()
  }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon
app.run()
