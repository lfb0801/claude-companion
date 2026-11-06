// Claude Code Companion for macOS: a menu bar app with a desktop overlay.
import AppKit
import SwiftUI

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
      status = makeStatusItem()
      model.start()
    }
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
    menu.addItem(withTitle: "Show toolbar", action: #selector(showToolbar), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Put tools away", action: #selector(disarm), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu
    return item
  }

  @objc func showToolbar() { toolbar.orderFrontRegardless() }
  @objc func disarm() { MainActor.assumeIsolated { model.disarm() } }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon
app.run()
