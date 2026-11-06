// What the companion server sends over /events and /log (see server.mjs, companion.mjs).
import Foundation

public struct Option: Codable, Equatable, Sendable {
  public var label: String
  public var description: String?
  public init(label: String, description: String? = nil) { self.label = label; self.description = description }
}

public struct Question: Codable, Equatable, Sendable {
  public var question: String
  public var header: String?
  public var options: [Option]
  public var multiSelect: Bool?
  public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool? = false) { self.question = question; self.header = header; self.options = options; self.multiSelect = multiSelect }
}

/// kind: permission | question | plan | input
public struct Prompt: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var text: String
  public var detail: String?
  public var tool: String?
  public var questions: [Question]?
  public var plan: String?
  public init(id: String, kind: String = "permission", text: String = "", detail: String? = nil, tool: String? = nil, questions: [Question]? = nil, plan: String? = nil) {
    self.id = id; self.kind = kind; self.text = text; self.detail = detail; self.tool = tool; self.questions = questions; self.plan = plan
  }
}

public struct Session: Codable, Equatable, Sendable {
  public var id: String
  public var cwd: String?
  public var folder: String?
  public var title: String?
  public var prompt: Prompt?
  public init(id: String, cwd: String? = nil, folder: String? = nil, title: String? = nil, prompt: Prompt? = nil) { self.id = id; self.cwd = cwd; self.folder = folder; self.title = title; self.prompt = prompt }
}

public struct LogLine: Codable, Equatable, Sendable {
  public var kind: String
  public var text: String
  public init(kind: String, text: String) { self.kind = kind; self.text = text }
}

public enum ServerEvent: Equatable, Sendable {
  case snapshot([Session])
  case session(Session)
  case end(String)
  case greet(String)
  case prompt(String, Prompt)
  case answered(String, prompt: String, source: String?)
  case log(String, [LogLine])

  private struct Raw: Decodable {
    var type: String
    var sessions: [Session]?
    var session: Session?
    var id: String?
    var promptObject: Prompt?
    var promptId: String?
    var source: String?
    var lines: [LogLine]?
    enum K: String, CodingKey { case type, sessions, session, id, prompt, source, lines }
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: K.self)
      type = try c.decode(String.self, forKey: .type)
      sessions = try c.decodeIfPresent([Session].self, forKey: .sessions)
      session = try c.decodeIfPresent(Session.self, forKey: .session)
      id = try c.decodeIfPresent(String.self, forKey: .id)
      source = try c.decodeIfPresent(String.self, forKey: .source)
      lines = try c.decodeIfPresent([LogLine].self, forKey: .lines)
      // "prompt" is an object on prompt events and an id on answered events.
      promptObject = try? c.decodeIfPresent(Prompt.self, forKey: .prompt)
      promptId = try? c.decodeIfPresent(String.self, forKey: .prompt)
    }
  }

  /// Decodes one SSE `data:` payload; nil for anything unknown or malformed.
  public static func decode(_ json: String) -> ServerEvent? {
    guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return nil }
    switch raw.type {
    case "snapshot": return raw.sessions.map { .snapshot($0) }
    case "session": return raw.session.map { .session($0) }
    case "end": return raw.id.map { .end($0) }
    case "greet": return raw.id.map { .greet($0) }
    case "prompt": if let id = raw.id, let p = raw.promptObject { return .prompt(id, p) }
    case "answered": if let id = raw.id, let p = raw.promptId { return .answered(id, prompt: p, source: raw.source) }
    case "log": if let id = raw.id { return .log(id, raw.lines ?? []) }
    default: break
    }
    return nil
  }
}

/// The session list, kept in arrival order. Mirrors state.js: only the first answer to a prompt counts.
public struct Sessions: Sendable {
  public private(set) var all: [Session] = []
  public init() {}
  public subscript(id: String) -> Session? { all.first { $0.id == id } }
  public mutating func apply(_ e: ServerEvent) {
    switch e {
    case .snapshot(let list): all = list
    case .session(let s):
      if let i = all.firstIndex(where: { $0.id == s.id }) {
        let prompt = all[i].prompt
        all[i] = s
        if s.prompt == nil { all[i].prompt = prompt }
      } else { all.append(s) }
    case .end(let id): all.removeAll { $0.id == id }
    case .prompt(let id, let p): if let i = all.firstIndex(where: { $0.id == id }) { all[i].prompt = p }
    case .answered(let id, let prompt, _): answered(id, prompt: prompt)
    case .greet, .log: break
    }
  }
  public mutating func answered(_ id: String, prompt: String) {
    if let i = all.firstIndex(where: { $0.id == id }), all[i].prompt?.id == prompt { all[i].prompt = nil }
  }
}

public struct Answer: Equatable, Sendable {
  public var session: String, prompt: String, decision: String, source: String
  public var answers: [String: String]?
  /// Notes added to a picked answer (right-click a card), keyed by question text.
  public var notes: [String: String]?
  /// Why you denied a permission or what should change in a plan (right-click Deny / Keep planning).
  public var message: String?
  public init(session: String, prompt: String, decision: String, source: String, answers: [String: String]? = nil, notes: [String: String]? = nil, message: String? = nil) {
    self.session = session; self.prompt = prompt; self.decision = decision; self.source = source; self.answers = answers; self.notes = notes; self.message = message
  }
}
