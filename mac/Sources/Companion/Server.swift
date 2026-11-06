// The companion backend (server.mjs in the repository root): live events over SSE, answers back.
// If nothing answers on 127.0.0.1:5173, the app starts the Node server itself and stops it on quit.
import Foundation
import StageCore

final class Server {
  static let base = URL(string: "http://127.0.0.1:5173")!
  var onEvent: (ServerEvent) -> Void = { _ in }
  var onConnected: (Bool) -> Void = { _ in }
  private var node: Process?
  private var task: Task<Void, Never>?

  /// The repository holding server.mjs: COMPANION_REPO, the app's Info.plist, or this source file's checkout.
  static var repo: URL {
    if let p = ProcessInfo.processInfo.environment["COMPANION_REPO"] { return URL(fileURLWithPath: p) }
    if let p = Bundle.main.object(forInfoDictionaryKey: "CompanionRepo") as? String { return URL(fileURLWithPath: p) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  func start() {
    task = Task { [weak self] in
      var started = false
      while !Task.isCancelled {
        guard let self else { return }
        do {
          try await self.stream()
        } catch {
          await MainActor.run { self.onConnected(false) }
          if !started { started = true; self.launchNode() }
          try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
      }
    }
  }

  /// Reads /events until the connection drops, handing each event to onEvent on the main thread.
  private func stream() async throws {
    var req = URLRequest(url: Server.base.appendingPathComponent("events"))
    req.timeoutInterval = 60 * 60 * 24
    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    await MainActor.run { onConnected(true) }
    for try await line in bytes.lines where line.hasPrefix("data: ") {
      if let e = ServerEvent.decode(String(line.dropFirst(6))) { await MainActor.run { onEvent(e) } }
    }
    throw URLError(.networkConnectionLost)
  }

  func answer(_ a: Answer) {
    var body: [String: Any] = ["session": a.session, "prompt": a.prompt, "decision": a.decision, "source": a.source]
    if let answers = a.answers { body["answers"] = answers }
    if let notes = a.notes { body["notes"] = notes }
    if let message = a.message { body["message"] = message }
    post("answer", body)
  }

  func log(_ session: String, _ done: @escaping ([LogLine]) -> Void) {
    var c = URLComponents(url: Server.base.appendingPathComponent("log/\(session)"), resolvingAgainstBaseURL: false)!
    c.queryItems = [URLQueryItem(name: "n", value: "80")]
    URLSession.shared.dataTask(with: c.url!) { data, _, _ in
      struct R: Decodable { var lines: [LogLine] }
      let lines = data.flatMap { try? JSONDecoder().decode(R.self, from: $0).lines } ?? []
      DispatchQueue.main.async { done(lines) }
    }.resume()
  }

  func post(_ path: String, _ body: [String: Any], _ done: ((Data?, Int) -> Void)? = nil) {
    var req = URLRequest(url: Server.base.appendingPathComponent(path))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: req) { data, res, _ in
      let status = (res as? HTTPURLResponse)?.statusCode ?? 0
      DispatchQueue.main.async { done?(data, status) }
    }.resume()
  }

  func get(_ path: String, _ done: @escaping (Data?) -> Void) {
    URLSession.shared.dataTask(with: Server.base.appendingPathComponent(path)) { data, _, _ in DispatchQueue.main.async { done(data) } }.resume()
  }

  private func launchNode() {
    let script = Server.repo.appendingPathComponent("server.mjs")
    guard FileManager.default.fileExists(atPath: script.path),
          let nodePath = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      NSLog("Companion: no server.mjs at \(script.path) or no node binary; start it with npm start")
      return
    }
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Companion")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let logFile = logs.appendingPathComponent("server.log")
    FileManager.default.createFile(atPath: logFile.path, contents: nil)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: nodePath)
    p.arguments = [script.path]
    p.currentDirectoryURL = Server.repo
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
    p.environment = env
    if let h = try? FileHandle(forWritingTo: logFile) { p.standardOutput = h; p.standardError = h }
    do { try p.run(); node = p; NSLog("Companion: started node server.mjs (pid \(p.processIdentifier)), log: \(logFile.path)") }
    catch { NSLog("Companion: could not start node: \(error)") }
  }

  func stop() { task?.cancel(); node?.terminate() }
}
