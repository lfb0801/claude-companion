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

/// The floating toolbar: tools, sound, sessions, connection.
struct Toolbar: View {
  @ObservedObject var model: AppModel
  var body: some View {
    HStack(spacing: 6) {
      tool("W", "Whip", \.whip, help: "Swing it to approve what the lash hits; click a prompt to stamp it with the handle (deny)")
      tool("G", "Cannon", \.cannon, help: "Hold the mouse to fire approvals")
      tool("D", "Stamp", \.stamp, help: "Click a prompt or its cards to request changes (deny)")
      tool("H", "Intern", \.intern, help: "Approves every prompt, in every session")
      Button { model.toggle(\.muted) } label: { Image(systemName: model.tools.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.help("Sound · \(HotKeys.symbol)M from any app")
      Menu {
        if model.sessions.all.isEmpty { Text("No sessions yet") }
        ForEach(model.sessions.all, id: \.id) { s in
          Button("\(s.prompt != nil ? "● " : "")\(s.folder ?? "session")\(s.title.map { $0.isEmpty ? "" : " · \($0)" } ?? "")") {
            if let p = s.prompt { model.open(session: s.id, prompt: p) }
          }
        }
      } label: { Text("Sessions \(model.sessions.all.count)") }.fixedSize()
      Circle().fill(model.connected ? lime : Color.gray).frame(width: 8, height: 8).help(model.connected ? "Connected to the companion server" : "Server offline, retrying")
    }
    .buttonStyle(.bordered).controlSize(.small)
    .padding(8).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
  }
  private func tool(_ key: String, _ name: String, _ kp: WritableKeyPath<Tools, Bool>, help: String) -> some View {
    let on = model.tools[keyPath: kp]
    return Button { model.toggle(kp) } label: { Text("\(key) \(name)").font(.system(.caption, design: .monospaced).bold()) }
      .tint(on ? lime : nil).buttonStyle(.borderedProminent).foregroundStyle(on ? Color.black : Color.primary)
      .help("\(help) · \(HotKeys.symbol)\(key) from any app")
  }
}
