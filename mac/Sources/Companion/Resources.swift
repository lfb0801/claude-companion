import AppKit

/// One line per click in ~/Library/Logs/Companion/events.log: did the companion get it, and if not,
/// which app's window was under the pointer. Clicks only; no keys are recorded.
func trace(_ s: String) {
  let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Companion")
  let url = dir.appendingPathComponent("events.log")
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
  if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
  else { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try? Data(line.utf8).write(to: url) }
}

enum ClickLog {
  nonisolated(unsafe) static var monitors: [Any] = []
  static func start() {
    // Clicks that reach the companion's own windows.
    monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in
      let w = e.window
      trace("companion got click in \(w.map { "\(type(of: $0)) level=\($0.level.rawValue) key=\($0.isKeyWindow) frame=\(NSStringFromRect($0.frame))" } ?? "no window") at \(NSStringFromPoint(NSEvent.mouseLocation))")
      return e
    } as Any)
    // Clicks that went to another app: what was under the pointer.
    monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
      let p = NSEvent.mouseLocation, h = NSScreen.screens.first?.frame.height ?? 0
      let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
      let hit = list.first { info in
        guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(CGPoint(x: p.x, y: h - p.y))
      }
      let mine = NSApp.windows.filter { $0.isVisible }.map { "\(type(of: $0)) level=\($0.level.rawValue) ignores=\($0.ignoresMouseEvents) frame=\(NSStringFromRect($0.frame))" }
      trace("click went elsewhere at \(NSStringFromPoint(p)): top window there belongs to \(hit?[kCGWindowOwnerName as String] ?? "?") layer=\(hit?[kCGWindowLayer as String] ?? "?"); companion windows: \(mine.joined(separator: " | "))")
    } as Any)
  }
}

/// Sprites and clips: Contents/Resources in the packaged .app, else SwiftPM's bundle (swift run).
func resource(_ name: String, _ ext: String) -> URL? {
  if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
  return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
}
