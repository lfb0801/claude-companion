// Shared by both apps. Each TCP connection carries one request.
import CryptoKit
import Foundation
import Network
import Security

enum PhoneWhipWire {
  static let service = "_phone-whip._tcp"

  /// Public and guest Wi-Fi often blocks mDNS or device-to-device traffic, so also allow a direct
  /// peer-to-peer (AWDL) link between the Mac and the iPhone.
  /// Some networks pass mDNS but block device-to-device TCP, so discovery works and the connection hangs.
  /// When a connection never becomes ready, the phone flips this and retries over the direct link only.
  nonisolated(unsafe) static var direct = false

  static func parameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    if direct { parameters.requiredInterfaceType = .other }
    return parameters
  }
  static let nonceSize = 16
  static let tagSize = 32
  static let publicKeySize = 32
  static let timeout = 3.0
  static let approvalTimeout = 45.0

  // Values 3–5 belonged to the previous, stateless whip controls.
  enum Action: UInt8 { case pair = 1, connect = 2, hold = 6, stamp = 7, dictation = 8, holdFeedback = 9 }
  enum Reply: UInt8 { case paired = 1, connected = 2, busy = 5, denied, storageError, armed, stamped, stampUnavailable, snapped }

  static let holdTimeout = 2.4
  static let pulseInterval = 0.6
  static let generationSize = 8
  enum Command: UInt8 { case pulse = 1, flick, drop }

  static func generationBytes(_ generation: UInt64) -> Data {
    withUnsafeBytes(of: generation.bigEndian) { Data($0) }
  }

  static func generation(_ bytes: Data) -> UInt64 {
    bytes.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) }
  }

  static func snapReply(sequence: UInt64, transcript: Data, key: SymmetricKey) -> Data {
    let number = generationBytes(sequence)
    return number + response(.snapped, transcript: snapTranscript(transcript, number), key: key)
  }

  static func verifySnap(_ bytes: Data, transcript: Data, key: SymmetricKey) -> UInt64? {
    guard bytes.count == generationSize + 1 + tagSize else { return nil }
    let number = Data(bytes.prefix(generationSize))
    guard verifyResponse(Data(bytes.dropFirst(generationSize)), transcript: snapTranscript(transcript, number),
                         key: key) == .snapped else { return nil }
    return generation(number)
  }

  private static func snapTranscript(_ transcript: Data, _ sequence: Data) -> Data {
    Data("PhoneWhip/2 snap feedback".utf8) + transcript + sequence
  }

  static func command(_ command: Command, sequence: UInt64, transcript: Data, key: SymmetricKey) -> Data {
    let tag = HMAC<SHA256>.authenticationCode(
      for: commandMessage(command, sequence: sequence, transcript: transcript), using: key)
    return Data([command.rawValue]) + Data(tag)
  }

  static func verifyCommand(_ bytes: Data, sequence: UInt64, transcript: Data, key: SymmetricKey) -> Command? {
    guard let value = bytes.first, let command = Command(rawValue: value),
          HMAC<SHA256>.isValidAuthenticationCode(Data(bytes.dropFirst()),
            authenticating: commandMessage(command, sequence: sequence, transcript: transcript), using: key)
    else { return nil }
    return command
  }

  private static func commandMessage(_ command: Command, sequence: UInt64, transcript: Data) -> Data {
    Data("PhoneWhip/2 hold command".utf8) + transcript + generationBytes(sequence) + Data([command.rawValue])
  }

  struct Hello {
    static let size = 50
    let action: Action
    let phone: UUID
    let mac: UUID
    let bytes: Data

    init(action: Action, phone: UUID, mac: UUID) {
      self.action = action; self.phone = phone; self.mac = mac
      bytes = Data([2, action.rawValue]) + Self.bytes(phone) + Self.bytes(mac) + PhoneWhipWire.nonce()
    }

    init?(_ data: Data) {
      guard data.count == Self.size, data[0] == 2, let action = Action(rawValue: data[1]) else { return nil }
      self.action = action
      phone = Self.uuid(data[2..<18]); mac = Self.uuid(data[18..<34])
      bytes = data
    }

    private static func bytes(_ id: UUID) -> Data {
      withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    private static func uuid(_ data: Data) -> UUID {
      UUID(uuid: data.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    }
  }

  static func nonce() -> Data {
    var random = SystemRandomNumberGenerator()
    return Data((0..<nonceSize).map { _ in UInt8.random(in: .min ... .max, using: &random) })
  }

  // Commit before seeing the Mac key so a relay cannot tune its key exchange to match the display.
  static func commitment(hello: Data, publicKey: Data) -> Data {
    Data(SHA256.hash(data: Data("PhoneWhip/2 commitment".utf8) + hello + publicKey))
  }

  // Bind the temporary key exchange to both identities, the action, and each side's contribution.
  static func pairingKey(local: Curve25519.KeyAgreement.PrivateKey, remote: Data, transcript: Data) throws -> SymmetricKey {
    let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote)
    return try local.sharedSecretFromKeyAgreement(with: publicKey).hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: Data(SHA256.hash(data: transcript)),
      sharedInfo: Data("PhoneWhip/2 pairing".utf8), outputByteCount: tagSize)
  }

  static func matchNumber(transcript: Data, key: SymmetricKey) -> String {
    let tag = HMAC<SHA256>.authenticationCode(for: Data("PhoneWhip/2 match".utf8) + transcript, using: key)
    let value = tag.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    return String(format: "%06u", value % 1_000_000)
  }

  static func proof(for transcript: Data, using key: SymmetricKey) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: requestMessage(transcript), using: key))
  }

  static func verifyProof(_ proof: Data, transcript: Data, key: SymmetricKey) -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: requestMessage(transcript), using: key)
  }

  private static func requestMessage(_ transcript: Data) -> Data { Data("PhoneWhip/2 request".utf8) + transcript }

  static func response(_ reply: Reply, transcript: Data, key: SymmetricKey) -> Data {
    let value = Data([reply.rawValue])
    let tag = HMAC<SHA256>.authenticationCode(for: replyMessage(transcript, value), using: key)
    return value + Data(tag)
  }

  static func verifyResponse(_ data: Data, transcript: Data, key: SymmetricKey) -> Reply? {
    guard let value = data.first, let reply = Reply(rawValue: value),
          HMAC<SHA256>.isValidAuthenticationCode(Data(data.dropFirst()),
            authenticating: replyMessage(transcript, Data([value])), using: key) else { return nil }
    return reply
  }

  private static func replyMessage(_ transcript: Data, _ value: Data) -> Data {
    Data("PhoneWhip/2 reply".utf8) + transcript + value
  }

  enum Dictation: Codable {
    case sessions
    case send(session: String, request: UUID, text: String)
    /// Like send, but interrupts the session's running turn first.
    case steer(session: String, request: UUID, text: String)
    /// A read-only fork of the session, asked this question, opened in Claude Desktop. The session never sees it.
    case sideChat(session: String, request: UUID, text: String)
    /// Questions Claude is waiting on, and the phone's answer to one of them.
    case questions
    case answer(session: String, prompt: String, decision: String, answers: [String: String]?, notes: [String: String]?)
    /// A whip at a session held on a prompt: approve it (first option of each question) and carry on.
    case goAhead(session: String)
  }

  /// A question prompt as the phone sees it (the Mac's StageCore models are not shared with iOS).
  struct QuestionCard: Codable, Identifiable {
    struct Option: Codable { let label: String; let description: String? }
    struct Question: Codable, Identifiable {
      let question: String
      let header: String?
      let options: [Option]
      let multiSelect: Bool
      var id: String { question }
    }
    let session: String
    let prompt: String
    let folder: String
    let title: String
    let cwd: String?
    let questions: [Question]
    var id: String { session + "/" + prompt }
  }

  struct DictationReply: Codable {
    struct Session: Codable, Identifiable {
      let id: String
      let folder: String
      let title: String
      let cwd: String?
      /// The session this one nests under: the one it was forked from, or its project's main session.
      let parent: String?
      /// waiting (held on a prompt), working (mid-turn) or idle. Absent from an older server.
      let state: String?
      /// What the agent said when its last turn ended. Absent until a turn has ended.
      let last: String?
    }

    var sessions: [Session]?
    var cards: [QuestionCard]?
    /// For an answer: false when the prompt was already answered (here, at the Mac or in the terminal).
    var answered: Bool?
    var queued: Bool?
    /// A side chat was started: it opens in Claude Desktop once its first answer is in.
    var startedSession: UUID?
    var error: String?
  }

  /// Bytes of dictated text per message. The wire frame below leaves room for far more.
  static let dictationLimit = 64 * 1_024
  private static let dictationFrameLimit = 256 * 1_024

  static func dictationFrame<T: Encodable>(_ value: T, reply: Bool, transcript: Data, key: SymmetricKey) throws -> Data {
    let json = try JSONEncoder().encode(value)
    let sealed = try ChaChaPoly.seal(json, using: key, authenticating: dictationContext(reply, transcript)).combined
    return withUnsafeBytes(of: UInt32(sealed.count).bigEndian) { Data($0) } + sealed
  }

  static func receiveDictation<T: Decodable>(_ type: T.Type, reply: Bool, transcript: Data, key: SymmetricKey,
                                            from connection: NWConnection, then: @escaping @MainActor (T?) -> Void) {
    receive(4, from: connection) { header in
      guard let header else { then(nil); return }
      let size = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
      guard (28...dictationFrameLimit).contains(size) else { then(nil); return }
      receive(size, from: connection) { bytes in
        guard let bytes, let box = try? ChaChaPoly.SealedBox(combined: bytes),
              let json = try? ChaChaPoly.open(box, using: key, authenticating: dictationContext(reply, transcript))
        else { then(nil); return }
        then(try? JSONDecoder().decode(type, from: json))
      }
    }
  }

  private static func dictationContext(_ reply: Bool, _ transcript: Data) -> Data {
    Data((reply ? "PhoneWhip/2 dictation reply" : "PhoneWhip/2 dictation request").utf8) + transcript
  }

  // Both peers run their Network callbacks on the main queue.
  static func receive(_ size: Int, from connection: NWConnection, then: @escaping @MainActor (Data?) -> Void) {
    connection.receive(minimumIncompleteLength: size, maximumLength: size) { data, _, _, error in
      MainActor.assumeIsolated { then(error == nil && data?.count == size ? data : nil) }
    }
  }

  static func send(_ data: Data, to connection: NWConnection, final: Bool = false) {
    connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                    completion: .contentProcessed { error in if error != nil { connection.cancel() } })
  }
}

extension Bundle {
  /// The Mac app's bundle identifier, COMPANION_BUNDLE_ID in the repository's .env. The iPhone app's own
  /// identifier is this plus ".phone-whip", so both ends arrive at the same value.
  static var companionID: String {
    let id = main.bundleIdentifier ?? "local.claude-companion"
    return id.hasSuffix(".phone-whip") ? String(id.dropLast(".phone-whip".count)) : id
  }
}

@MainActor
struct PhoneWhipTrust {
  let id: UUID
  private let service: String

  init(service: String = Bundle.companionID + ".phone-whip.trust") {
    self.service = service
    let defaults = UserDefaults.standard
    if let value = defaults.string(forKey: service), let id = UUID(uuidString: value) {
      self.id = id
    } else {
      id = UUID()
      defaults.set(id.uuidString, forKey: service)
    }
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
  }

  func key(for peer: UUID) -> SymmetricKey? {
    var lookup = query
    lookup[kSecAttrAccount as String] = peer.uuidString
    lookup[kSecReturnData as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data, data.count == PhoneWhipWire.tagSize else { return nil }
    return SymmetricKey(data: data)
  }

  func remember(_ peer: UUID, key: SymmetricKey) -> Bool {
    var item = query
    item[kSecAttrAccount as String] = peer.uuidString
    let data = key.withUnsafeBytes { Data($0) }
    let update = [kSecValueData as String: data]
    let status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    item[kSecValueData as String] = data
    #if os(iOS)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #endif
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  func forgetAll() -> Bool {
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}

@MainActor
final class PhoneWhipRequest {
  private let connection: NWConnection
  private var completion: ((PhoneWhipWire.Reply?, SymmetricKey?, PhoneWhipWire.DictationReply?) -> Void)?
  private let dictation: PhoneWhipWire.Dictation?
  /// False when the TCP connection never became ready, so the network (not the Mac) is the problem.
  private(set) var reachedMac = false

  convenience init(endpoint: NWEndpoint, phone: UUID, mac: UUID, action: PhoneWhipWire.Action, key: SymmetricKey? = nil,
                   onMatch: @escaping (String) -> Void = { _ in },
                   completion: @escaping (PhoneWhipWire.Reply?, SymmetricKey?) -> Void) {
    self.init(endpoint: endpoint, phone: phone, mac: mac, action: action, key: key, onMatch: onMatch, dictation: nil) {
      reply, pairedKey, _ in completion(reply, pairedKey)
    }
  }

  convenience init(endpoint: NWEndpoint, phone: UUID, mac: UUID, key: SymmetricKey, dictation: PhoneWhipWire.Dictation,
                   completion: @escaping (PhoneWhipWire.DictationReply?) -> Void) {
    self.init(endpoint: endpoint, phone: phone, mac: mac, action: .dictation, key: key, onMatch: { _ in },
              dictation: dictation) { _, _, reply in completion(reply) }
  }

  private init(endpoint: NWEndpoint, phone: UUID, mac: UUID, action: PhoneWhipWire.Action, key: SymmetricKey?,
               onMatch: @escaping (String) -> Void, dictation: PhoneWhipWire.Dictation?,
               completion: @escaping (PhoneWhipWire.Reply?, SymmetricKey?, PhoneWhipWire.DictationReply?) -> Void) {
    self.dictation = dictation
    self.completion = completion
    let connection = NWConnection(to: endpoint, using: PhoneWhipWire.parameters())
    self.connection = connection
    let hello = PhoneWhipWire.Hello(action: action, phone: phone, mac: mac)
    connection.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        switch state {
        case .ready: self?.reachedMac = true
        case .failed, .cancelled: self?.finish(nil)
        default: break
        }
      }
    }
    connection.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      if let self, !self.reachedMac { self.finish(nil) }
    }
    if action == .pair {
      let local = Curve25519.KeyAgreement.PrivateKey()
      let publicKey = local.publicKey.rawRepresentation
      let offer = hello.bytes + PhoneWhipWire.commitment(hello: hello.bytes, publicKey: publicKey)
      PhoneWhipWire.send(offer, to: connection)
      PhoneWhipWire.receive(PhoneWhipWire.nonceSize + PhoneWhipWire.publicKeySize, from: connection) { [weak self] challenge in
        guard let self, self.completion != nil else { return }
        guard let challenge, let key = try? PhoneWhipWire.pairingKey(
          local: local, remote: Data(challenge.suffix(PhoneWhipWire.publicKeySize)), transcript: offer + challenge + publicKey)
        else { self.finish(nil); return }
        let transcript = offer + challenge + publicKey
        onMatch(PhoneWhipWire.matchNumber(transcript: transcript, key: key))
        PhoneWhipWire.send(publicKey, to: connection)
        self.authenticate(transcript, key: key)
      }
    } else if let key {
      PhoneWhipWire.send(hello.bytes, to: connection)
      PhoneWhipWire.receive(PhoneWhipWire.nonceSize, from: connection) { [weak self] challenge in
        guard let self, self.completion != nil else { return }
        guard let challenge else { self.finish(nil); return }
        self.authenticate(hello.bytes + challenge, key: key)
      }
    }
    let timeout = action == .pair ? PhoneWhipWire.approvalTimeout + PhoneWhipWire.timeout : PhoneWhipWire.timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
  }

  private func authenticate(_ transcript: Data, key: SymmetricKey) {
    PhoneWhipWire.send(PhoneWhipWire.proof(for: transcript, using: key), to: connection)
    if let dictation {
      guard let frame = try? PhoneWhipWire.dictationFrame(dictation, reply: false, transcript: transcript, key: key)
      else { finish(nil); return }
      PhoneWhipWire.send(frame, to: connection)
      PhoneWhipWire.receiveDictation(PhoneWhipWire.DictationReply.self, reply: true, transcript: transcript, key: key,
                                     from: connection) { [weak self] reply in self?.finish(nil, dictationReply: reply) }
      return
    }
    PhoneWhipWire.receive(1 + PhoneWhipWire.tagSize, from: connection) { [weak self] data in
      let reply = data.flatMap { PhoneWhipWire.verifyResponse($0, transcript: transcript, key: key) }
      self?.finish(reply, pairedKey: reply == .paired ? key : nil)
    }
  }

  func cancel() {
    completion = nil
    connection.cancel()
  }

  private func finish(_ reply: PhoneWhipWire.Reply?, pairedKey: SymmetricKey? = nil,
                      dictationReply: PhoneWhipWire.DictationReply? = nil) {
    let callback = completion
    cancel()
    callback?(reply, pairedKey, dictationReply)
  }
}

/// One ordered stream per press, starting with an authenticated hold and ending with a drop.
@MainActor
final class PhoneWhipHold {
  private let connection: NWConnection
  private let key: SymmetricKey
  private var transcript: Data?
  private var sequence: UInt64 = 0
  private var queuedFlick = false
  private var released = false
  private var onEnd: ((Bool) -> Void)?
  private let onSnap: (() -> Void)?
  private var lastSnap: UInt64?
  private var reachedMac = false

  init(endpoint: NWEndpoint, phone: UUID, mac: UUID, generation: UInt64, key: SymmetricKey,
       onArmed: @escaping () -> Void, onSnap: (() -> Void)? = nil, onEnd: @escaping (Bool) -> Void) {
    self.key = key
    self.onEnd = onEnd
    self.onSnap = onSnap
    connection = NWConnection(to: endpoint, using: PhoneWhipWire.parameters())
    let hello = PhoneWhipWire.Hello(action: onSnap == nil ? .hold : .holdFeedback, phone: phone, mac: mac)
    let offer = hello.bytes + PhoneWhipWire.generationBytes(generation)
    connection.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        switch state {
        case .ready: self?.reachedMac = true
        case .failed, .cancelled: self?.finish()
        default: break
        }
      }
    }
    connection.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      if let self, !self.reachedMac {
        PhoneWhipWire.direct.toggle()
        self.finish()
      }
    }
    PhoneWhipWire.send(offer, to: connection)
    PhoneWhipWire.receive(PhoneWhipWire.nonceSize, from: connection) { [weak self] challenge in
      guard let self, self.onEnd != nil else { return }
      guard let challenge else { self.finish(); return }
      let transcript = offer + challenge
      PhoneWhipWire.send(PhoneWhipWire.proof(for: transcript, using: key), to: self.connection)
      PhoneWhipWire.receive(1 + PhoneWhipWire.tagSize, from: self.connection) { [weak self] ack in
        guard let self, self.onEnd != nil else { return }
        guard let ack, PhoneWhipWire.verifyResponse(ack, transcript: transcript, key: key) == .armed
        else { self.finish(); return }
        self.transcript = transcript
        if self.queuedFlick { self.send(.flick) }
        if self.released {
          self.send(.drop)
        } else {
          onArmed()
          self.pulse()
        }
        if self.onSnap != nil {
          self.receiveFeedback(transcript)
        } else {
          PhoneWhipWire.receive(1, from: self.connection) { [weak self] _ in self?.finish() }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + PhoneWhipWire.timeout) { [weak self] in
      if self?.transcript == nil { self?.finish() }
    }
  }

  func flick() {
    guard !released, onEnd != nil else { return }
    if transcript != nil { send(.flick) } else { queuedFlick = true }
  }

  func release() {
    guard !released, onEnd != nil else { return }
    released = true
    if transcript != nil { send(.drop) }
    else if !queuedFlick { finish(); return }
    // Give an already-detected flick a short chance to precede the drop on the same stream.
    DispatchQueue.main.asyncAfter(deadline: .now() + (onSnap == nil ? 0.45 : 1.2)) { [self] in finish() }
  }

  private func receiveFeedback(_ transcript: Data) {
    PhoneWhipWire.receive(PhoneWhipWire.generationSize + 1 + PhoneWhipWire.tagSize, from: connection) { [weak self] bytes in
      guard let self, self.onEnd != nil else { return }
      guard let bytes, let snap = PhoneWhipWire.verifySnap(bytes, transcript: transcript, key: self.key),
            snap < self.sequence, self.lastSnap.map({ snap > $0 }) ?? true else { self.finish(); return }
      self.lastSnap = snap
      self.onSnap?()
      self.receiveFeedback(transcript)
    }
  }

  private func pulse() {
    DispatchQueue.main.asyncAfter(deadline: .now() + PhoneWhipWire.pulseInterval) { [weak self] in
      guard let self, !self.released, self.onEnd != nil else { return }
      self.send(.pulse)
      self.pulse()
    }
  }

  private func send(_ command: PhoneWhipWire.Command) {
    guard let transcript else { return }
    PhoneWhipWire.send(PhoneWhipWire.command(command, sequence: sequence, transcript: transcript, key: key),
                       to: connection, final: command == .drop)
    sequence &+= 1
  }

  private func finish() {
    let callback = onEnd
    onEnd = nil
    connection.cancel()
    callback?(!released)
  }
}
