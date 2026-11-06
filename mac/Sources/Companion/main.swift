// Claude Code Companion for macOS: a menu bar app with a desktop overlay.
import AppKit
import SwiftUI
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
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
      ClickLog.start()
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
      HotKey(key: kVK_ANSI_M, letter: "M", title: "Sound on/off") { m.toggle(\.muted) },
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
        MainActor.assumeIsolated { if let self, let p, abs(p.frame.maxY - self.toolbarTop) > 0.5, !self.resizing { self.toolbarTop = p.frame.maxY } }
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

  @MainActor private func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(systemSymbolName: "figure.wave", accessibilityDescription: "Companion")
    let menu = NSMenu()
    // Every hotkey, with its shortcut shown; a refused one says so instead of firing.
    for (i, k) in hotKeys.enumerated() {
      let taken = refused.contains { $0.letter == k.letter }
      let mi = NSMenuItem(title: taken ? "\(k.title) (\(HotKeys.symbol)\(k.letter) taken by another app)" : k.title, action: #selector(runHotKey(_:)), keyEquivalent: k.letter.lowercased())
      mi.keyEquivalentModifierMask = [.control, .option]
      mi.tag = i; mi.target = self
      menu.addItem(mi)
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu
    return item
  }

  @objc func runHotKey(_ sender: NSMenuItem) { hotKeys[sender.tag].action() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon
app.run()
