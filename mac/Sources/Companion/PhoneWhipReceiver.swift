// Advertises a local endpoint. A crack requires proof from an approved, remembered iPhone.
import CryptoKit
import Foundation
import Network
import OSLog

@MainActor
final class PhoneWhipReceiver {
  let trust: PhoneWhipTrust
  private let log = Logger(subsystem: Bundle.companionID, category: "PhoneWhip")
  private var listener: NWListener?
  private var clients: [ObjectIdentifier: NWConnection] = [:]
  private var approval: ObjectIdentifier?
  private var lastApproval = -Double.infinity
  private var lastCrack = -Double.infinity
  private var generations: [UUID: UInt64] = [:]
  private var hold: (client: ObjectIdentifier, phone: UUID, deadline: TimeInterval)?
  var running: Bool { listener != nil }
  var onArm: () -> Void = {}
  var onDrop: () -> Void = {}
  var onFlick: (@escaping () -> Void) -> Bool = { _ in false }
  private var pendingSnaps: Set<ObjectIdentifier> = []
  var onStamp: () -> Bool = { false }
  var onDictation: (PhoneWhipWire.Dictation, @escaping (PhoneWhipWire.DictationReply) -> Void) -> Void = { _, done in
    done(.init(error: "Claude Companion is unavailable."))
  }
  var onApproval: (String, @escaping (Bool) -> Void) -> Void = { _, decide in decide(false) }
  var onApprovalEnded: () -> Void = {}

  init(trust: PhoneWhipTrust) { self.trust = trust }

  func start(name: String, onError: @escaping (Error) -> Void) throws {
    guard listener == nil else { return }
    let parameters = PhoneWhipWire.parameters()
    parameters.acceptLocalOnly = true
    let listener = try NWListener(using: parameters)
    listener.service = NWListener.Service(name: name, type: PhoneWhipWire.service,
                                          txtRecord: NWTXTRecord(["id": trust.id.uuidString, "hold": "1", "stamp": "1", "dictation": "1", "sideChat": "1",
                                                                  "feedback": "1", "questions": "1"]))
    self.listener = listener
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      MainActor.assumeIsolated {
        guard let self, let listener, self.listener === listener else { return }
        if case .failed(let error) = state { self.stop(); onError(error) }
      }
    }
    listener.newConnectionHandler = { [weak self, weak listener] connection in
      MainActor.assumeIsolated {
        guard let self, let listener, self.listener === listener else { connection.cancel(); return }
        self.accept(connection)
      }
    }
    listener.start(queue: .main)
  }

  func stop() {
    listener?.cancel()
    listener = nil
    cancelClients()
  }

  func forgetPhones() -> Bool {
    cancelClients()
    return trust.forgetAll()
  }

  private func cancelClients() {
    for client in clients.values { client.cancel() }
    clients.removeAll()
    pendingSnaps.removeAll()
    if let hold { endHold(hold.client) }
    if approval != nil {
      approval = nil
      onApprovalEnded()
    }
  }

  private func accept(_ client: NWConnection) {
    guard clients.count < 8 else { client.cancel(); return }
    let id = ObjectIdentifier(client)
    clients[id] = client
    client.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        guard let self else { return }
        switch state {
        case .failed, .cancelled:
          self.clients.removeValue(forKey: id)
          self.pendingSnaps.remove(id)
          self.endHold(id)
          if self.approval == id {
            self.log.notice("Pending iPhone pairing connection closed")
            self.approval = nil
            self.onApprovalEnded()
          }
        default: break
        }
      }
    }
    client.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + PhoneWhipWire.timeout) { [weak self, weak client] in
      if self?.approval != id && self?.hold?.client != id && self?.pendingSnaps.contains(id) != true { client?.cancel() }
    }
    PhoneWhipWire.receive(PhoneWhipWire.Hello.size, from: client) { [weak self] data in
      guard let self, self.clients[id] === client, let data, let hello = PhoneWhipWire.Hello(data),
            hello.mac == self.trust.id else { client.cancel(); return }
      if hello.action == .pair {
        self.log.notice("Received iPhone pairing request")
        self.pair(hello, client: client)
      } else if let key = self.trust.key(for: hello.phone) {
        if hello.action == .hold || hello.action == .holdFeedback {
          PhoneWhipWire.receive(PhoneWhipWire.generationSize, from: client) { [weak self] generation in
            guard let self, self.clients[id] === client, let generation else { client.cancel(); return }
            self.authenticateHold(hello, generation: generation, client: client, key: key)
          }
        } else {
          let challenge = PhoneWhipWire.nonce()
          let transcript = hello.bytes + challenge
          PhoneWhipWire.send(challenge, to: client)
          self.authenticate(client, transcript: transcript, key: key) {
            if hello.action == .dictation {
              self.receiveDictation(client, transcript: transcript, key: key)
              return
            }
            let result: PhoneWhipWire.Reply = hello.action == .stamp
              ? (self.onStamp() ? .stamped : .stampUnavailable) : .connected
            self.reply(result, client: client, transcript: transcript, key: key)
          }
        }
      } else { client.cancel() }
    }
  }

  private func receiveDictation(_ client: NWConnection, transcript: Data, key: SymmetricKey) {
    let id = ObjectIdentifier(client)
    PhoneWhipWire.receiveDictation(PhoneWhipWire.Dictation.self, reply: false, transcript: transcript, key: key,
                                   from: client) { [weak self] request in
      guard let self, self.clients[id] === client, let request else { client.cancel(); return }
      self.onDictation(request) { [weak self] reply in
        guard self?.clients[id] === client else { return }
        guard let frame = try? PhoneWhipWire.dictationFrame(reply, reply: true, transcript: transcript, key: key)
        else { client.cancel(); return }
        PhoneWhipWire.send(frame, to: client, final: true)
      }
    }
  }

  private func authenticateHold(_ hello: PhoneWhipWire.Hello, generation: Data, client: NWConnection, key: SymmetricKey) {
    let challenge = PhoneWhipWire.nonce()
    let transcript = hello.bytes + generation + challenge
    PhoneWhipWire.send(challenge, to: client)
    authenticate(client, transcript: transcript, key: key) {
      let next = PhoneWhipWire.generation(generation)
      guard next > (self.generations[hello.phone] ?? 0) else { client.cancel(); return }
      self.generations[hello.phone] = next
      if let hold = self.hold, hold.phone != hello.phone {
        self.reply(.busy, client: client, transcript: transcript, key: key)
        return
      }

      let previous = self.hold?.client
      let id = ObjectIdentifier(client)
      self.hold = (id, hello.phone, ProcessInfo.processInfo.systemUptime + PhoneWhipWire.holdTimeout)
      if let previous { self.clients[previous]?.cancel() }
      self.onArm()
      PhoneWhipWire.send(PhoneWhipWire.response(.armed, transcript: transcript, key: key), to: client)
      self.receiveCommand(client, sequence: 0, transcript: transcript, key: key, feedback: hello.action == .holdFeedback)
      self.watchHold(client)
    }
  }

  private func receiveCommand(_ client: NWConnection, sequence: UInt64, transcript: Data, key: SymmetricKey, feedback: Bool) {
    let id = ObjectIdentifier(client)
    PhoneWhipWire.receive(1 + PhoneWhipWire.tagSize, from: client) { [weak self] bytes in
      guard let self, let hold = self.hold, hold.client == id else { client.cancel(); return }
      let now = ProcessInfo.processInfo.systemUptime
      guard now < hold.deadline, let bytes,
            let command = PhoneWhipWire.verifyCommand(bytes, sequence: sequence, transcript: transcript, key: key) else {
        self.endHold(id)
        client.cancel()
        return
      }
      if command == .drop {
        self.endHold(id)
        if self.pendingSnaps.contains(id) {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak client] in client?.cancel() }
        } else { client.cancel() }
        return
      }
      self.hold?.deadline = now + PhoneWhipWire.holdTimeout
      if command == .flick && now - self.lastCrack >= 0.68 {
        if self.onFlick({ [weak self, weak client] in
          guard feedback, let self, let client, self.pendingSnaps.remove(id) != nil else { return }
          let reply = PhoneWhipWire.snapReply(sequence: sequence, transcript: transcript, key: key)
          PhoneWhipWire.send(reply, to: client, final: self.hold?.client != id)
        }) {
          self.lastCrack = now
          if feedback { self.pendingSnaps.insert(id) }
        }
      }
      self.receiveCommand(client, sequence: sequence &+ 1, transcript: transcript, key: key, feedback: feedback)
    }
  }

  private func watchHold(_ client: NWConnection) {
    DispatchQueue.main.asyncAfter(deadline: .now() + PhoneWhipWire.pulseInterval) { [weak self, weak client] in
      guard let self, let client, let hold = self.hold, hold.client == ObjectIdentifier(client) else { return }
      if ProcessInfo.processInfo.systemUptime >= hold.deadline {
        self.endHold(hold.client)
        client.cancel()
      } else { self.watchHold(client) }
    }
  }

  private func endHold(_ id: ObjectIdentifier) {
    guard hold?.client == id else { return }
    hold = nil
    onDrop()
  }

  private func pair(_ hello: PhoneWhipWire.Hello, client: NWConnection) {
    PhoneWhipWire.receive(PhoneWhipWire.tagSize, from: client) { [weak self] commitment in
      guard let self, let commitment else { client.cancel(); return }
      let local = Curve25519.KeyAgreement.PrivateKey()
      let challenge = PhoneWhipWire.nonce() + local.publicKey.rawRepresentation
      PhoneWhipWire.send(challenge, to: client)
      PhoneWhipWire.receive(PhoneWhipWire.publicKeySize, from: client) { [weak self] publicKey in
        guard let self, let publicKey,
              commitment == PhoneWhipWire.commitment(hello: hello.bytes, publicKey: publicKey)
        else { client.cancel(); return }

        let transcript = hello.bytes + commitment + challenge + publicKey
        guard let key = try? PhoneWhipWire.pairingKey(local: local, remote: publicKey, transcript: transcript)
        else { client.cancel(); return }

        self.authenticate(client, transcript: transcript, key: key) {
          self.approve(hello, client: client, transcript: transcript, key: key)
        }
      }
    }
  }

  private func authenticate(_ client: NWConnection, transcript: Data, key: SymmetricKey, then: @escaping () -> Void) {
    let id = ObjectIdentifier(client)
    PhoneWhipWire.receive(PhoneWhipWire.tagSize, from: client) { [weak self] proof in
      guard self?.clients[id] === client, let proof,
            PhoneWhipWire.verifyProof(proof, transcript: transcript, key: key)
      else { client.cancel(); return }
      then()
    }
  }

  private func approve(_ hello: PhoneWhipWire.Hello, client: NWConnection, transcript: Data, key: SymmetricKey) {
    let now = ProcessInfo.processInfo.systemUptime
    guard approval == nil, now - lastApproval >= 3 else {
      reply(.busy, client: client, transcript: transcript, key: key)
      return
    }
    let id = ObjectIdentifier(client)
    approval = id
    lastApproval = now
    log.notice("iPhone pairing verified and waiting for Mac approval")
    // Detect a phone that closes the request while the approval is still on screen.
    PhoneWhipWire.receive(1, from: client) { [weak self] _ in
      if self?.approval == id { client.cancel() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + PhoneWhipWire.approvalTimeout) { [weak self, weak client] in
      if let self, self.approval == id {
        self.log.notice("iPhone pairing approval expired")
        client?.cancel()
      }
    }
    onApproval(PhoneWhipWire.matchNumber(transcript: transcript, key: key)) { [weak self, weak client] allowed in
      guard let self, let client, self.approval == id, self.clients[id] === client else { return }
      self.approval = nil
      self.onApprovalEnded()
      self.log.notice("Mac responded to iPhone pairing: \(allowed ? "allow" : "deny", privacy: .public)")
      let result: PhoneWhipWire.Reply = allowed ? (self.trust.remember(hello.phone, key: key) ? .paired : .storageError) : .denied
      self.reply(result, client: client, transcript: transcript, key: key)
    }
  }

  private func reply(_ reply: PhoneWhipWire.Reply, client: NWConnection, transcript: Data, key: SymmetricKey) {
    PhoneWhipWire.send(PhoneWhipWire.response(reply, transcript: transcript, key: key), to: client, final: true)
  }

}
