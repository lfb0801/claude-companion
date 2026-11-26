// Summons Remarc's own tools by pressing its global shortcuts (its URL scheme has no actions).
// Needs Accessibility permission to post key events; without it macOS is asked to show the prompt.
import AppKit
import ApplicationServices

enum Remarc {
  enum Tool { case screenshot, note }
  /// Remarc's defaults: screenshot comment is ⌃⌥S, comment on selection is ⌃⌥C.
  @MainActor static func press(_ tool: Tool) {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(opts) else { return }
    let key: CGKeyCode = tool == .screenshot ? 1 : 8
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: down)
      e?.flags = [.maskControl, .maskAlternate]
      e?.post(tap: .cghidEventTap)
    }
  }
}
