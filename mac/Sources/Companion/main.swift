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
      hotKeys = makeHotKeys()
      refused = HotKeys.register(hotKeys)
      status = makeStatusItem()
      model.start()
    }
  }

  var hotKeys: [HotKey] = []
  var refused: [HotKey] = []

  /// ⌃⌥ + key, from any app.
  @MainActor private func makeHotKeys() -> [HotKey] {
    let m = model!
    return [
      HotKey(key: kVK_ANSI_W, letter: "W", title: "Whip") { m.toggle(\.whip) },
      HotKey(key: kVK_ANSI_G, letter: "G", title: "Cannon") { m.toggle(\.cannon) },
      HotKey(key: kVK_ANSI_D, letter: "D", title: "Stamp") { m.toggle(\.stamp) },
      HotKey(key: kVK_ANSI_H, letter: "H", title: "Approval Intern") { m.toggle(\.intern) },
      HotKey(key: kVK_ANSI_M, letter: "M", title: "Sound on/off") { m.toggle(\.muted) },
      HotKey(key: kVK_ANSI_X, letter: "X", title: "Put tools away") { m.disarm() },
      HotKey(key: kVK_ANSI_T, letter: "T", title: "Show toolbar") { [weak self] in self?.toolbar.orderFrontRegardless() },
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
    let host = NSHostingView(rootView: Toolbar(model: model))
    p.contentView = host
    p.setContentSize(host.fittingSize)
    let s = NSScreen.main?.visibleFrame ?? .zero
    p.setFrameOrigin(NSPoint(x: s.midX - host.fittingSize.width / 2, y: s.maxY - host.fittingSize.height - 8))
    p.orderFrontRegardless()
    return p
  }

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
