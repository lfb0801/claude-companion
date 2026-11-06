// Global hotkeys (⌃⌥ + key) that work from any app. Carbon's RegisterEventHotKey needs no
// Accessibility permission, unlike watching every key press.
import AppKit
import Carbon.HIToolbox

struct HotKey {
  let key: Int          // kVK_ANSI_* virtual key code
  let letter: String    // for menus and tooltips
  let title: String
  let action: () -> Void
}

/// The C callback can't capture context, so registered actions live here, by hotkey id.
nonisolated(unsafe) private var actions: [UInt32: () -> Void] = [:]

enum HotKeys {
  static let modifiers = UInt32(controlKey | optionKey)
  static let symbol = "⌃⌥"
  private static var refs: [EventHotKeyRef] = []
  private static var installed = false

  /// Registers each hotkey; returns the ones macOS refused (already taken by another app).
  @discardableResult
  static func register(_ keys: [HotKey]) -> [HotKey] {
    if !installed {
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        if let f = actions[id.id] { DispatchQueue.main.async { f() } }
        return noErr
      }, 1, &spec, nil, nil)
      installed = true
    }
    var refused: [HotKey] = []
    for (i, k) in keys.enumerated() {
      var ref: EventHotKeyRef?
      let id = EventHotKeyID(signature: OSType(0x43435048), id: UInt32(i + 1)) // 'CCPH'
      if RegisterEventHotKey(UInt32(k.key), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
        refs.append(ref); actions[id.id] = k.action
      } else {
        refused.append(k)
        NSLog("Companion: \(symbol)\(k.letter) is taken by another app")
      }
    }
    return refused
  }
}
