import Foundation
import OSLog

/// A side chat: a read-only fork of a running session, asked one question from the phone.
/// The fork answers headlessly in the session's own folder, then opens in Claude Desktop.
/// The main session never sees it, and the fork is told not to touch the code.
@MainActor
final class SideChatLauncher {
  private let logger = Logger(subsystem: Bundle.companionID, category: "SideChat")
  private var started: [UUID: Date] = [:]

  func start(session: String, request: UUID, text: String, done: @escaping (PhoneWhipWire.DictationReply) -> Void) {
    started = started.filter { $0.value > Date.now }
    if started[request] != nil { done(.init(startedSession: request)); return }
    guard UUID(uuidString: session) != nil else { done(.init(error: "That Claude session is unavailable.")); return }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf8.count <= PhoneWhipWire.dictationLimit, !text.utf8.contains(0) else {
      done(.init(error: "The question is empty, too long, or contains unsupported text."))
      return
    }
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let paths = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    guard let claude = paths.first(where: { fm.isExecutableFile(atPath: $0) }) else {
      done(.init(error: "Claude Code isn’t installed in a standard location on your Mac."))
      return
    }
    // The fork is saved under the folder it runs in, so it must run where the session works.
    guard let cwd = Self.folder(of: session.lowercased(), home: home) else {
      done(.init(error: "Couldn’t find that session’s conversation on your Mac."))
      return
    }

    let executable = URL(fileURLWithPath: claude)
    let fork = request.uuidString.lowercased()
    let input = Pipe()
    let firstTurn = makeProcess(executable: executable, cwd: cwd, arguments: [
      "--print", "--resume", session.lowercased(), "--fork-session", "--session-id", fork,
      "--permission-mode", "plan", "--disallowedTools", "Edit Write NotebookEdit",
      "--name", "Side chat · \(cwd.lastPathComponent)",
    ])
    firstTurn.standardInput = input
    firstTurn.terminationHandler = { [weak self] process in
      let status = process.terminationStatus
      Task { @MainActor in self?.openInDesktop(executable: executable, cwd: cwd, session: fork, status: status) }
    }
    do { try firstTurn.run() } catch {
      done(.init(error: "Couldn’t start the side chat."))
      return
    }
    started[request] = .now.addingTimeInterval(15 * 60)
    // Its records all carry the new id, so tell the companion which session it hangs under.
    var adopt = URLRequest(url: Server.base.appendingPathComponent("inbox/side-chat"))
    adopt.httpMethod = "POST"
    adopt.setValue("application/json", forHTTPHeaderField: "Content-Type")
    adopt.httpBody = try? JSONSerialization.data(withJSONObject: ["session": fork, "parent": session.lowercased()])
    URLSession.shared.dataTask(with: adopt).resume()
    // Through stdin, so the question stays out of the process arguments.
    let prompt = Data(Self.prompt(text).utf8)
    DispatchQueue.global(qos: .userInitiated).async {
      defer { try? input.fileHandleForWriting.close() }
      try? input.fileHandleForWriting.write(contentsOf: prompt)
    }
    done(.init(startedSession: request))
  }

  static func prompt(_ question: String) -> String {
    """
    [companion] This is a side chat: a copy of the conversation above, opened from the user's phone to ask about it. \
    The main session is still working in this same folder and does not see this chat. Answer the question only. \
    Do not edit, create or delete files, do not run commands that change anything (no installs, builds that write, \
    git commits, checkouts or stashes), and do not message or start other sessions. Reading files and running \
    read-only commands is fine. If the answer needs a change, describe it instead of making it.

    The user's question:
    \(question)
    """
  }

  /// The folder a session works in, from the first `cwd` its saved conversation records.
  private static func folder(of session: String, home: URL) -> URL? {
    let projects = home.appendingPathComponent(".claude/projects")
    guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
    for dir in dirs {
      let file = dir.appendingPathComponent("\(session).jsonl")
      guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
      defer { try? handle.close() }
      let head = (try? handle.read(upToCount: 256 * 1_024)) ?? Data()
      for line in head.split(separator: UInt8(ascii: "\n")) {
        if let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
           let cwd = entry["cwd"] as? String, FileManager.default.fileExists(atPath: cwd) {
          return URL(fileURLWithPath: cwd)
        }
      }
    }
    return nil
  }

  private func openInDesktop(executable: URL, cwd: URL, session: String, status: Int32) {
    if status != 0 { logger.error("Side chat \(session, privacy: .public) first turn exited with status \(status).") }
    // `claude --desktop` refuses to run without a terminal on its output, so give it one with script(1).
    let handoff = makeProcess(executable: URL(fileURLWithPath: "/usr/bin/script"), cwd: cwd,
                              arguments: ["-q", "/dev/null", executable.path, "--desktop", "--resume", session])
    let logger = self.logger
    handoff.terminationHandler = { process in
      if process.terminationStatus != 0 {
        logger.error("Desktop handoff for side chat \(session, privacy: .public) exited with status \(process.terminationStatus).")
      }
    }
    do { try handoff.run() } catch {
      logger.error("Couldn’t open the side chat in Claude Desktop: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func makeProcess(executable: URL, cwd: URL, arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = executable
    process.currentDirectoryURL = cwd
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return process
  }
}
