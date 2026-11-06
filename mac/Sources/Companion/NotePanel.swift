// "Pick with a note": a small AppKit window next to a right-clicked answer card.
// Plain AppKit on purpose: no SwiftUI hosting, so no self-sizing layout loops.
import AppKit

final class NotePanel: NSPanel, NSTextFieldDelegate {
  private let field = NSTextField()
  private let submit: (String) -> Void
  private let cancel: () -> Void
  private var finished = false

  init(option: String, beside anchor: NSRect, submit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
    self.submit = submit; self.cancel = cancel
    let size = NSSize(width: 380, height: 132)
    super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    title = "Add a note"
    level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isReleasedWhenClosed = false

    let label = NSTextField(labelWithString: "Pick “\(option)” with this note:")
    label.font = .boldSystemFont(ofSize: 13)
    field.placeholderString = "e.g. but keep the old behaviour as a fallback"
    field.delegate = self
    let pick = NSButton(title: "Pick with note", target: self, action: #selector(send))
    pick.keyEquivalent = "\r"
    let back = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
    back.keyEquivalent = "\u{1b}"
    let buttons = NSStackView(views: [NSView(), back, pick])
    buttons.orientation = .horizontal
    let stack = NSStackView(views: [label, field, buttons])
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView(frame: NSRect(origin: .zero, size: size))
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor), field.widthAnchor.constraint(equalToConstant: size.width - 32),
      buttons.widthAnchor.constraint(equalToConstant: size.width - 32),
    ])
    contentView = content

    // Beside the card: to its right if there is room, else to its left; kept on screen.
    let screen = NSScreen.main?.visibleFrame ?? .zero
    var x = anchor.maxX + 12
    if x + size.width > screen.maxX - 8 { x = anchor.minX - 12 - size.width }
    x = max(screen.minX + 8, x)
    let y = max(screen.minY + 8, min(screen.maxY - size.height - 30, anchor.midY - size.height / 2))
    setFrameOrigin(NSPoint(x: x, y: y))
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    makeFirstResponder(field)
  }

  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) { dismiss() }
  override func close() { if !finished { finished = true; cancel() }; super.close() }

  @objc private func send() {
    guard !finished else { return }
    finished = true
    let text = field.stringValue
    super.close()
    submit(text)
  }
  @objc private func dismiss() { close() }
}
