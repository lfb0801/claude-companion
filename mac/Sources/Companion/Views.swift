// Native panels: the hover log and the floating toolbar. (Prompts are answered with cards on the overlay.)
import SwiftUI
import StageCore

private let lime = Color(nsColor: .lime)

/// Recent transcript lines beside a hovered character; follows new lines.
struct LogPanel: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.logTitle.0).font(.system(.body, design: .monospaced).bold()).foregroundStyle(lime)
        if !model.logTitle.1.isEmpty { Text(model.logTitle.1).font(.system(.caption, design: .monospaced)).foregroundStyle(Color(white: 0.8)) }
      }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(lime.opacity(0.15))
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, l in
              Text(l.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(color(l.kind)).frame(maxWidth: .infinity, alignment: .leading).id(i)
            }
            if model.logLines.isEmpty { Text("No transcript lines yet").font(.system(size: 11, design: .monospaced)).foregroundStyle(.gray) }
          }.padding(10)
        }
        .onChange(of: model.logLines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
      }
    }
    .background(Color(nsColor: NSColor(hex: 0x0b0c0a, alpha: 0.96)))
    .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(lime, lineWidth: 2))
  }
  private func color(_ k: String) -> Color {
    switch k { case "user": Color(nsColor: NSColor(hex: 0xa8c4e8)); case "tool": lime; case "result": Color(nsColor: NSColor(hex: 0x8a8f7a)); case "error": Color(nsColor: NSColor(hex: 0xff8a7a)); default: Color(nsColor: NSColor(hex: 0xc9ccb8)) }
  }
}

/// The floating toolbar: tools, sound, sessions, connection. The line under the buttons names whatever
/// the pointer is over, because native tooltips do not appear on a panel that never takes focus.
struct Toolbar: View {
  @ObservedObject var model: AppModel
  @State private var frames: [String: HintFrame] = [:]
  /// What the pointer is over, from the pointer position the hosting view reports (see HoverHostingView).
  private var hint: (name: String, text: String)? {
    guard let p = model.toolbarPointer, let h = frames.first(where: { $0.value.rect.insetBy(dx: -3, dy: -3).contains(p) }) else { return nil }
    return (h.key, h.value.text)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      buttons
      Color.clear.frame(height: 30).overlay(alignment: .topLeading) {
        if let h = hint {
          (Text(h.name).bold().foregroundColor(lime) + Text("  " + h.text).foregroundColor(.secondary)).font(.system(size: 11)).lineLimit(2)
        } else {
          Text("Hover a button to see what it does").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
      }
    }
    .padding(8).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
    .coordinateSpace(name: "toolbar")
    .onPreferenceChange(HintFrames.self) { frames = $0 }
  }
  private var buttons: some View {
    HStack(spacing: 6) {
      tool("W", "lasso", "Whip", \.whip, help: "Swing it to approve what the lash hits; click a prompt to stamp it with the handle (deny)")
      tool("G", "scope", "Cannon", \.cannon, help: "Hold the mouse to fire approvals")
      tool("D", "square.and.pencil", "Stamp", \.stamp, help: "Click a prompt or its cards to request changes (deny)")
      tool("H", "person.fill.checkmark", "Approval Intern", \.intern, help: "Approves every prompt, in every session")
      Button { model.toggle(\.muted) } label: { Image(systemName: model.tools.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
        .hint("Sound", "Mute or unmute the stage · \(HotKeys.symbol)M from any app")
      Menu {
        if model.sessions.all.isEmpty { Text("No sessions yet") }
        ForEach(model.sessions.all, id: \.id) { s in
          let name = "\(s.prompt != nil ? "● " : "")\(s.folder ?? "session")\(s.title.map { $0.isEmpty ? "" : " · \($0)" } ?? "")"
          Toggle(name, isOn: Binding(get: { model.selectedSession == s.id }, set: { _ in model.open(session: s.id, prompt: s.prompt) }))
        }
      } label: {
        let picked = model.sessions.all.first { $0.id == model.selectedSession }
        Text(picked.map { "✓ \($0.folder ?? "session")" } ?? "Sessions \(model.sessions.all.count)")
      }.fixedSize().hint("Sessions", "Pick a session to open its transcript and answer its prompt")
      Divider().frame(height: 16)
      Button { Remarc.press(.screenshot) } label: { Image(systemName: "camera.viewfinder") }
        .hint("Remarc screenshot", "Capture part of the screen as a Remarc comment · \(HotKeys.symbol)S")
      Button { Remarc.press(.note) } label: { Image(systemName: "note.text.badge.plus") }
        .hint("Remarc note", "Comment on the text selected in the app behind this bar · \(HotKeys.symbol)C")
      Button { model.startRemarc() } label: {
        Image(systemName: model.remarcResult.map { $0.ok ? ($0.message == "Starting…" ? "ellipsis.bubble" : "checkmark.bubble") : "exclamationmark.bubble" } ?? "text.bubble")
      }.hint("Remarc link", model.remarcResult?.message ?? "Link the main session so Remarc comments arrive as prompts and get routed to nested sessions")
      Circle().fill(model.connected ? lime : Color.gray).frame(width: 8, height: 8)
        .hint("Connection", model.connected ? "Connected to the companion server" : "Server offline, retrying")
    }
    .buttonStyle(.bordered).controlSize(.small)
  }
  private func tool(_ key: String, _ icon: String, _ name: String, _ kp: WritableKeyPath<Tools, Bool>, help: String) -> some View {
    let on = model.tools[keyPath: kp]
    return Button { model.toggle(kp) } label: { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
      .tint(on ? lime : nil).buttonStyle(.borderedProminent)
      .hint(name, "\(help) · \(HotKeys.symbol)\(key) from any app")
  }
}

struct HintFrame: Equatable { var rect: CGRect; var text: String }

struct HintFrames: PreferenceKey {
  static let defaultValue: [String: HintFrame] = [:]
  static func reduce(value: inout [String: HintFrame], nextValue: () -> [String: HintFrame]) { value.merge(nextValue()) { $1 } }
}

private extension View {
  /// Registers this view's frame so the toolbar's caption line can name it while the pointer is over it
  /// (and sets a native tooltip too).
  func hint(_ name: String, _ text: String) -> some View {
    help("\(name): \(text)").background(GeometryReader { g in
      Color.clear.preference(key: HintFrames.self, value: [name: HintFrame(rect: g.frame(in: .named("toolbar")), text: text)])
    })
  }
}
