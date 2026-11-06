// Claude Code Companion for macOS: a menu bar app with a desktop overlay.
import AppKit
import SwiftUI
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var model: AppModel!
  var overlay: OverlayController!
  var toolbar: NSPanel!
  var status: NSStatusItem!

  func applicationDidFinishLaunching(_ n: Notification) {
    MainActor.assumeIsolated {
      model = AppModel()
      overlay = OverlayController(model: model)
      toolbar = makeToolbar()
      model.hideToolbar = { [weak self] in self?.setToolbar(visible: false) }
      hotKeys = makeHotKeys()
      refused = HotKeys.register(hotKeys)
      status = makeStatusItem()
      model.start()
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

  func applicationWillTerminate(_ n: Notification) { MainActor.assumeIsolated { model.server.stop() } }

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
    // The tools live on the toolbar; the menu is for the toolbar itself, sound, and quitting.
    let menu = NSMenu()
    menu.delegate = self
    let bar = NSMenuItem(title: "Show Toolbar", action: #selector(toggleToolbar), keyEquivalent: "t")
    bar.keyEquivalentModifierMask = [.control, .option]; bar.target = self; bar.tag = 1
    menu.addItem(bar)
    let mute = NSMenuItem(title: "Mute Sound", action: #selector(toggleMute), keyEquivalent: "")
    mute.target = self; mute.tag = 2
    menu.addItem(mute)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Claude Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu
    return item
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    MainActor.assumeIsolated {
      menu.item(withTag: 1)?.title = toolbar.isVisible ? "Hide Toolbar" : "Show Toolbar"
      menu.item(withTag: 2)?.state = model.tools.muted ? .on : .off
    }
  }
  @MainActor @objc func toggleToolbar() { setToolbar(visible: !toolbar.isVisible) }
  @MainActor @objc func toggleMute() { model.toggle(\.muted) }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon
app.run()
