// The toolbar lives in a panel of an app that is never active, where SwiftUI's onHover and native
// tooltips stay silent. This view tracks the pointer itself and hands it to the model.
import AppKit
import SwiftUI

final class HoverHostingView<Content: View>: NSHostingView<Content> {
  weak var model: AppModel?
  private var area: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area { removeTrackingArea(area) }
    let a = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
    addTrackingArea(a); area = a
  }
  private func report(_ e: NSEvent) {
    let p = convert(e.locationInWindow, from: nil)
    model?.toolbarPointer = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
  }
  private var keys: Timer?
  private func watchOption() {
    keys?.invalidate()
    // Modifier state is read straight from the system: no key-event permission, and it works while the pointer rests.
    keys = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.model?.optionHeld = NSEvent.modifierFlags.contains(.option) }
    }
    model?.optionHeld = NSEvent.modifierFlags.contains(.option)
  }
  override func mouseEntered(with e: NSEvent) { report(e); watchOption() }
  override func mouseMoved(with e: NSEvent) { report(e) }
  override func mouseExited(with e: NSEvent) { model?.toolbarPointer = nil; keys?.invalidate(); keys = nil; model?.optionHeld = false }
}
