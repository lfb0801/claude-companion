// Native panels: the prompt card, the hover log, and the floating toolbar.
import SwiftUI
import StageCore

private let ink = Color(nsColor: .ink), cream = Color(nsColor: .cream), lime = Color(nsColor: .lime)

/// Click a prompt (no tool armed): allow / deny, pick answers, or approve a plan.
struct PromptCard: View {
  let prompt: Prompt
  let folder: String
  let title: String
  let answer: (_ decision: String, _ answers: [String: String]?) -> Void
  let cancel: () -> Void
  @State private var picked: [Int: Set<String>] = [:]
  @State private var other: [Int: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(folder)\(title.isEmpty ? "" : " · \(title)")".uppercased()).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(Color(nsColor: NSColor(hex: 0x9a4d17)))
      Text(prompt.text).font(.system(.title3, design: .monospaced).bold()).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
      if let d = prompt.detail, !d.isEmpty, prompt.kind != "question" { Text(d).font(.system(.body, design: .monospaced)).foregroundStyle(ink.opacity(0.7)) }
      switch prompt.kind {
      case "question": questions
      case "plan": ScrollView { Text(prompt.plan ?? "").font(.system(.callout, design: .monospaced)).foregroundStyle(ink).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10) }
          .frame(maxHeight: 360).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
      default: EmptyView()
      }
      HStack {
        Spacer()
        switch prompt.kind {
        case "question": Button("Decline") { answer("deny", nil) }; Button("Answer") { answer("allow", collected()) }.keyboardShortcut(.defaultAction)
        case "plan": Button("Keep planning") { answer("deny", nil) }; Button("Approve plan") { answer("allow", nil) }.keyboardShortcut(.defaultAction)
        case "input": Button("Dismiss") { answer("allow", nil) }.keyboardShortcut(.defaultAction)
        default: Button("Deny") { answer("deny", nil) }; Button("Allow") { answer("allow", nil) }.keyboardShortcut(.defaultAction)
        }
      }.padding(.top, 4)
    }
    .padding(22).frame(width: 560).background(cream)
    .onExitCommand { cancel() }
  }

  private var questions: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array((prompt.questions ?? []).enumerated()), id: \.offset) { i, q in
        VStack(alignment: .leading, spacing: 6) {
          Text("\(q.header.map { "\($0) · " } ?? "")\(q.question)").font(.system(.body, design: .monospaced).bold()).foregroundStyle(ink)
          ForEach(q.options, id: \.label) { o in
            Button { toggle(i, o.label, multi: q.multiSelect == true) } label: {
              HStack(alignment: .top) {
                Image(systemName: selected(i, o.label) ? (q.multiSelect == true ? "checkmark.square.fill" : "largecircle.fill.circle") : (q.multiSelect == true ? "square" : "circle"))
                VStack(alignment: .leading) { Text(o.label).bold(); if let d = o.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(ink.opacity(0.7)) } }
              }.foregroundStyle(ink).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
          TextField("Other answer", text: Binding(get: { other[i] ?? "" }, set: { other[i] = $0 })).textFieldStyle(.roundedBorder)
        }.padding(10).overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(0.2)))
      }
    }
    .onAppear { for (i, q) in (prompt.questions ?? []).enumerated() where q.multiSelect != true { if let f = q.options.first { picked[i] = [f.label] } } }
  }
  private func selected(_ i: Int, _ l: String) -> Bool { picked[i]?.contains(l) == true }
  private func toggle(_ i: Int, _ l: String, multi: Bool) {
    if multi { var s = picked[i] ?? []; if s.contains(l) { s.remove(l) } else { s.insert(l) }; picked[i] = s } else { picked[i] = [l] }
  }
  /// Typed "other" text wins over the picked options for that question.
  private func collected() -> [String: String] {
    var out: [String: String] = [:]
    for (i, q) in (prompt.questions ?? []).enumerated() {
      let typed = (other[i] ?? "").trimmingCharacters(in: .whitespaces)
      out[q.question] = typed.isEmpty ? q.options.map(\.label).filter { selected(i, $0) }.joined(separator: ", ") : typed
    }
    return out
  }
}

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
      tool("H", "Intern", \.intern, help: "Approves every prompt, in every session")
      Button { model.toggle(\.muted) } label: { Image(systemName: model.tools.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.help("Sound · \(HotKeys.symbol)M from any app")
      Menu {
        if model.sessions.all.isEmpty { Text("No sessions yet") }
        ForEach(model.sessions.all, id: \.id) { s in
          Button("\(s.prompt != nil ? "● " : "")\(s.folder ?? "session")\(s.title.map { $0.isEmpty ? "" : " · \($0)" } ?? "")") {
            if let p = s.prompt { model.openCard(session: s.id, prompt: p) }
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
