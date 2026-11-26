import AVFoundation
import CoreMotion
import Network
import SwiftUI

@main
@MainActor
struct PhoneWhipApp: App {
  var body: some Scene {
    WindowGroup { PhoneWhipView() }
  }
}

@MainActor
private final class PhoneWhip: ObservableObject {
  struct Mac: Identifiable {
    let id: UUID
    let name: String
    let endpoint: NWEndpoint
    let supportsHold: Bool
    let supportsStamp: Bool
    let supportsDictation: Bool
    let supportsSideChat: Bool
    let supportsFeedback: Bool
    let supportsQuestions: Bool

    init?(_ result: NWBrowser.Result) {
      guard case .service(let name, _, _, _) = result.endpoint,
            case .bonjour(let txt) = result.metadata,
            let id = txt["id"].flatMap(UUID.init(uuidString:)) else { return nil }
      self.id = id
      self.name = name
      endpoint = result.endpoint
      supportsHold = txt["hold"] == "1"
      supportsStamp = txt["stamp"] == "1"
      supportsDictation = txt["dictation"] == "1"
      supportsSideChat = txt["sideChat"] == "1"
      supportsFeedback = txt["feedback"] == "1"
      supportsQuestions = txt["questions"] == "1"
    }
  }

  @Published private(set) var macs: [Mac] = []
  @Published private(set) var selected: Mac?
  @Published private(set) var paired = false
  @Published private(set) var sending = false
  @Published private(set) var match: String?
  @Published private(set) var controlIssue: String?
  @Published private(set) var cards: [PhoneWhipWire.QuestionCard] = []
  @Published private(set) var answerIssue: String?
  @Published private(set) var changeCount = 0
  @Published private(set) var archiveCount = 0
  @Published private(set) var hurt: [String: Date] = [:]
  private var steerSession: String?
  /// What a flick sends while steering a session from the phone.
  enum Steer { case speedUp, change, goAhead, approve }
  private var steerKind = Steer.speedUp
  private var changeRequest: PhoneWhipRequest?
  private var questionRequest: PhoneWhipRequest?
  private var answering = false
  @Published private(set) var status = "Looking for Claude Companion…"
  private let trust = PhoneWhipTrust()
  private let lastMacKey = "PhoneWhipLastMac"
  private let motion = CMMotionManager()
  private var browser: NWBrowser?
  private var request: PhoneWhipRequest?
  private var hold: PhoneWhipHold?
  private let generationKey = "PhoneWhipHoldGeneration"
  private var allowAutoConnect = true
  private var motionDetector = PhoneToolMotion()
  private var activeTool: PhoneTool?
  private let feedback = PhoneToolFeedback()
  private var stampTriggered = false
  private var motionRun = 0
  private var lastFlick = -Double.infinity

  var hasMotion: Bool { motion.isDeviceMotionAvailable }
  var canStamp: Bool { paired && selected?.supportsStamp == true }
  var canHold: Bool { paired && selected?.supportsHold == true && hasMotion }

  func browse() {
    if browser != nil { return }
    allowAutoConnect = true
    status = "Looking for Claude Companion…"
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PhoneWhipWire.service, domain: "local."), using: PhoneWhipWire.parameters())
    self.browser = browser
    browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
      MainActor.assumeIsolated {
        guard let self, let browser, self.browser === browser else { return }
        self.updateMacs(results.compactMap(Mac.init))
      }
    }
    browser.stateUpdateHandler = { [weak self, weak browser] state in
      MainActor.assumeIsolated {
        guard let self, let browser, self.browser === browser else { return }
        switch state {
        case .waiting(let error), .failed(let error):
          if case .dns(let code) = error, code == -65570 {
            self.status = "Allow Local Network access for Phone Whip in Settings."
          } else {
            self.status = "Couldn’t browse the local network."
          }
        case .ready:
          if self.macs.isEmpty { self.status = "Looking for Claude Companion…" }
        default: break
        }
      }
    }
    browser.start(queue: .main)
  }

  private func updateMacs(_ discovered: [Mac]) {
    var seen = Set<UUID>()
    macs = discovered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .filter { seen.insert($0.id).inserted }
    if let selected {
      if let updated = macs.first(where: { $0.id == selected.id }) {
        self.selected = updated
      } else {
        resetConnection()
        allowAutoConnect = true
        status = "\(selected.name) is offline. Looking for it…"
      }
    }
    if selected == nil, allowAutoConnect,
       let previous = UserDefaults.standard.string(forKey: lastMacKey),
       let mac = macs.first(where: { $0.id.uuidString == previous }),
       trust.key(for: mac.id) != nil {
      choose(mac)
    } else if selected == nil, !macs.isEmpty {
      status = "Select your Mac to connect."
    }
  }

  func choose(_ mac: Mac) {
    resetConnection()
    allowAutoConnect = false
    selected = mac
    send(trust.key(for: mac.id) == nil ? .pair : .connect)
  }

  func pairAgain() { send(.pair) }

  func chooseAnotherMac() {
    resetConnection()
    allowAutoConnect = false
    status = "Select your Mac to connect."
  }

  func suspend(background: Bool) {
    arm(false)
    stopMotion()
    if background {
      resetConnection()
      browser?.cancel()
      browser = nil
      macs = []
    } else if paired {
      request?.cancel()
      request = nil
      sending = false
    }
  }

  private func resetConnection() {
    questionRequest?.cancel()
    questionRequest = nil
    answering = false
    cards = []
    answerIssue = nil
    arm(false)
    stopMotion()
    request?.cancel()
    request = nil
    sending = false
    paired = false
    match = nil
    selected = nil
    controlIssue = nil
  }

  func arm(_ held: Bool) {
    if !held {
      let released = hold
      hold = nil
      if activeTool == .whip { stopMotion() }
      released?.release()
      if released != nil, let selected { status = "Connected to \(selected.name)." }
      return
    }
    guard canHold, hold == nil, activeTool == nil, let mac = selected, let key = trust.key(for: mac.id) else { return }

    controlIssue = nil
    let generation = UserDefaults.standard.integer(forKey: generationKey) + 1
    UserDefaults.standard.set(generation, forKey: generationKey)
    status = "Equipping the whip on \(mac.name)…"
    hold = PhoneWhipHold(endpoint: mac.endpoint, phone: trust.id, mac: mac.id, generation: UInt64(generation), key: key,
                         onArmed: { [weak self] in self?.status = "Whip equipped on Mac." },
                         onSnap: mac.supportsFeedback ? { [weak self] in self?.feedback.sound(.whip) } : nil,
                         onEnd: { [weak self] interrupted in
      guard let self, self.hold != nil,
            UserDefaults.standard.integer(forKey: self.generationKey) == generation else { return }
      self.arm(false)
      if interrupted { self.controlIssue = "Whip disconnected. Release and try again." }
    })

    beginMotion(.whip)
  }

  func armStamp() {
    guard canStamp, hasMotion, !sending, activeTool == nil else { return }
    controlIssue = nil
    stampTriggered = false
    beginMotion(.stamp)
  }

  func releaseStamp() {
    if activeTool == .stamp { stopMotion() }
  }

  func finishStamp(quickTap: Bool) {
    releaseStamp()
    if quickTap && !stampTriggered { stamp() }
  }

  private func beginMotion(_ tool: PhoneTool) {
    motionRun += 1
    motionDetector = PhoneToolMotion()
    activeTool = tool
    feedback.ramp(PhoneToolMotion.armedIntensity)
    let run = motionRun
    motion.deviceMotionUpdateInterval = 1.0 / 60.0
    motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
      MainActor.assumeIsolated {
        guard let self, self.motionRun == run else { return }
        if let sample { self.sample(sample, tool: tool) }
        else if error != nil {
          self.arm(false)
          self.stopMotion()
          self.controlIssue = "Motion is unavailable on this device."
        }
      }
    }
  }

  private func stopMotion() {
    motionRun += 1
    steerSession = nil
    activeTool = nil
    motion.stopDeviceMotionUpdates()
    feedback.stop()
  }

  private func sample(_ sample: CMDeviceMotion, tool: PhoneTool) {
    let rotation = sample.rotationRate
    let acceleration = sample.userAcceleration
    let speed = hypot(hypot(rotation.x, rotation.y), rotation.z)
    let force = hypot(hypot(acceleration.x, acceleration.y), acceleration.z)
    let enabled = tool == .whip ? sample.timestamp - lastFlick >= 0.70 : !sending && !stampTriggered
    switch motionDetector.sample(tool, rotation: speed, force: force, enabled: enabled) {
    case .ramp(let level):
      feedback.ramp(level)
    case .actuate:
      feedback.stop()
      switch tool {
      case .whip:
        lastFlick = sample.timestamp
        if let session = steerSession {
          feedback.sound(.whip)
          switch steerKind {
          case .change: requestChange(session: session)
          case .speedUp: requestSpeedUp(session: session)
          case .goAhead: requestGoAhead(session: session)
          case .approve: approve(session: session)
          }
        } else {
          hold?.flick()
        }
      case .stamp:
        stampTriggered = true
        stamp()
      }
    }
  }

  func stamp() {
    guard canStamp, !sending, let mac = selected, let key = trust.key(for: mac.id) else { return }
    controlIssue = nil
    sending = true
    request = PhoneWhipRequest(endpoint: mac.endpoint, phone: trust.id, mac: mac.id, action: .stamp, key: key) {
      [weak self] reply, _ in
      guard let self else { return }
      self.sending = false
      self.request = nil
      switch reply {
      case .stamped: self.feedback.sound(.stamp)
      case .stampUnavailable: self.controlIssue = "Check the Mac cursor or wait a moment."
      default: self.controlIssue = "Couldn’t reach the Mac."
      }
    }
  }

  private func send(_ action: PhoneWhipWire.Action, retried: Bool = false) {
    guard !sending, let mac = selected else { return }
    status = "Connecting to \(mac.name)…"
    sending = true
    request = PhoneWhipRequest(endpoint: mac.endpoint, phone: trust.id, mac: mac.id, action: action,
                               key: action == .pair ? nil : trust.key(for: mac.id), onMatch: { [weak self] number in
      self?.match = number
      self?.status = "Check that the number matches on your Mac, then click Allow there."
    }) { [weak self] reply, key in
      guard let self else { return }
      let unreachable = reply == nil && self.request?.reachedMac == false
      self.sending = false
      self.request = nil
      self.match = nil
      if unreachable && !retried {
        // The network may block direct Wi-Fi connections; try the other path once.
        PhoneWhipWire.direct.toggle()
        self.send(action, retried: true)
        return
      }
      switch reply {
      case .paired:
        guard let key, self.trust.remember(mac.id, key: key) else {
          self.status = "This iPhone couldn’t save the pairing in Keychain."
          return
        }
        self.didConnect(to: mac)
      case .connected: self.didConnect(to: mac)
      case .armed, .stamped, .stampUnavailable, .snapped: break
      case .busy: self.status = "The Mac is handling another request. Try again shortly."
      case .denied: self.status = "Pairing was declined on the Mac."
      case .storageError: self.status = "The Mac couldn’t save the pairing in Keychain."
      case nil:
        self.paired = false
        self.arm(false)
        self.status = action == .pair ? "Pairing timed out or the Mac is unavailable."
          : "Couldn’t verify the connection. Retry or pair again if this Mac forgot the iPhone."
      }
    }
  }

  func dictation(_ operation: PhoneWhipWire.Dictation, on macID: UUID,
                 completion: @escaping (PhoneWhipWire.DictationReply?) -> Void) -> PhoneWhipRequest? {
    guard paired, let mac = selected, mac.id == macID, mac.supportsDictation,
          let key = trust.key(for: macID) else { return nil }
    return PhoneWhipRequest(endpoint: mac.endpoint, phone: trust.id, mac: macID, key: key,
                            dictation: operation, completion: completion)
  }

  func refreshQuestions() {
    guard paired, !answering, questionRequest == nil, let mac = selected, mac.supportsQuestions else { return }
    questionRequest = dictation(.questions, on: mac.id) { [weak self] reply in
      guard let self else { return }
      self.questionRequest = nil
      if !self.answering, let cards = reply?.cards { self.cards = cards }
    }
  }

  func answer(_ card: PhoneWhipWire.QuestionCard, decision: String, answers: [String: String]?) {
    guard !answering, let mac = selected else { return }
    answering = true
    answerIssue = nil
    questionRequest?.cancel()
    questionRequest = nil
    let operation = PhoneWhipWire.Dictation.answer(session: card.session, prompt: card.prompt, decision: decision,
                                                   answers: answers, notes: nil)
    questionRequest = dictation(operation, on: mac.id) { [weak self] reply in
      guard let self else { return }
      self.questionRequest = nil
      self.answering = false
      if reply?.answered != nil {
        // Answered here, or already answered elsewhere: either way the card is done.
        self.cards.removeAll { $0.id == card.id }
        self.refreshQuestions()
      } else {
        self.answerIssue = reply?.error ?? "Couldn’t reach the Mac. Try again."
      }
    }
    if questionRequest == nil { answering = false; answerIssue = "Couldn’t reach the Mac. Try again." }
  }

  /// Ask a session to archive itself in Claude Desktop. Queued like dictation: it lands once the session is idle.
  func archive(session: String) {
    guard changeRequest == nil, let mac = selected else { return }
    let text = "[companion] The user asked from their phone that you archive this session. Do not start anything new. "
      + "If work is unfinished or uncommitted, say so in one short sentence first. Then archive yourself: load "
      + "mcp__ccd_session_mgmt__archive_session (and list_sessions to find your own session) with ToolSearch, and archive "
      + "the session you are running in. Do not archive any other session."
    changeRequest = dictation(.send(session: session, request: UUID(), text: text), on: mac.id) { [weak self] reply in
      guard let self else { return }
      self.changeRequest = nil
      if reply?.queued == true { self.archiveCount += 1 } else { self.controlIssue = reply?.error ?? "Couldn’t reach the Mac." }
    }
    if changeRequest == nil { controlIssue = "Couldn’t reach the Mac." }
  }

  /// Whip or stamp on a working session: say it mid-turn. The plugin interrupts the turn, then submits this.
  func steer(session: String, text: String) {
    guard changeRequest == nil, let mac = selected else { return }
    hurt[session] = Date().addingTimeInterval(1.6)
    changeRequest = dictation(.steer(session: session, request: UUID(), text: text), on: mac.id) { [weak self] reply in
      guard let self else { return }
      self.changeRequest = nil
      if reply?.queued == true { self.changeCount += 1 } else { self.controlIssue = reply?.error ?? "Couldn’t reach the Mac." }
    }
    if changeRequest == nil { controlIssue = "Couldn’t reach the Mac." }
  }

  func requestChange(session: String) {
    steer(session: session, text: "[companion] The user held the stamp and flicked their phone: they want you to do this "
      + "differently. If you are working, stop what you are doing. Ask them what to change. Ask them what to work on with the AskUserQuestion tool "
      + "(a few concrete options), then wait for the answer.")
  }

  func requestSpeedUp(session: String) {
    steer(session: session, text: "[companion] The user cracked the whip from their phone: you are taking too long. "
      + "Wrap this turn up as soon as you can. Stop any long-running work that is not 100% required before the turn "
      + "ends (long scripts, slow local test runs the CI will also run, extra checks and polish), finish or park only "
      + "what is essential, and end the turn with a short note of what you skipped.")
  }

  /// Whip at an idle session: whatever it proposed or asked permission for, it may do now.
  func requestGoAhead(session: String) {
    steer(session: session, text: "[companion] The user cracked the whip from their phone: you have permission. "
      + "Go ahead and do what you proposed or asked about, and get it done without asking again. If you proposed "
      + "several things, do the one you recommended.")
  }

  /// Whip at a session held on a prompt: approve it on the Mac. If it was already answered, just say go ahead.
  func approve(session: String) {
    guard changeRequest == nil, let mac = selected else { return }
    hurt[session] = Date().addingTimeInterval(1.6)
    changeRequest = dictation(.goAhead(session: session), on: mac.id) { [weak self] reply in
      guard let self else { return }
      self.changeRequest = nil
      if reply?.answered == true {
        self.changeCount += 1
        self.refreshQuestions()
      } else if reply?.answered == false {
        self.requestGoAhead(session: session)
      } else {
        self.controlIssue = reply?.error ?? "Couldn’t reach the Mac."
      }
    }
    if changeRequest == nil { controlIssue = "Couldn’t reach the Mac." }
  }

  /// Hold to aim, flick to steer a session: speed it up, change course, or give it the go-ahead.
  /// Needs no Mac cursor, so no hold stream to the Mac.
  func armSteer(_ held: Bool, session: String, kind: Steer = .speedUp) {
    if !held {
      if steerSession != nil { steerSession = nil; if activeTool == .whip { stopMotion() } }
      return
    }
    guard hasMotion, activeTool == nil else { return }
    controlIssue = nil
    steerKind = kind
    steerSession = session
    beginMotion(.whip)
  }

  func retry() {
    if let selected { choose(selected) }
  }

  private func didConnect(to mac: Mac) {
    paired = true
    UserDefaults.standard.set(mac.id.uuidString, forKey: lastMacKey)
    status = "Connected to \(mac.name)."
  }

}

@MainActor
private struct PhoneWhipView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var phone = PhoneWhip()
  @StateObject private var dictation = PhoneDictation()
  @GestureState private var holding = false
  @GestureState private var stampHolding = false
  @State private var stampStartedAt: Date?
  @GestureState private var micHolding = false
  @State private var micPressStarted = false
  @State private var openCard: String?
  @State private var dictatedAnswer: String?
  /// The session whose last message is on screen while it is held.
  @State private var reading: String?
  /// The session whose archive is waiting on a confirm.
  @State private var archiveTarget: String?
  /// The session whose long-press menu is open. It stays open until an option is picked or it is closed.
  @State private var menuFigure: String?
  /// The option a swipe from the held figure points at; letting go there picks it.
  @State private var menuAim: SessionMenuDirection?

  @Environment(\.colorScheme) private var scheme
  private var pal: Palette { .for(scheme) }

  var body: some View {
    Group {
      if phone.paired { controller }
      else { pairing }
    }
    .background(pal.base.ignoresSafeArea())
    .tint(pal.mauve)
    .onChange(of: dictationMac?.id, initial: true) { _, _ in
      guard let mac = dictationMac else {
        dictation.configure(macID: nil, connect: nil)
        return
      }
      dictation.configure(macID: mac.id) { [phone] operation, done in
        phone.dictation(operation, on: mac.id, completion: done)
      }
      if scenePhase == .active { dictation.refresh() }
    }
    .task(id: scenePhase) {
      // Questions are checked every couple of seconds; dictation keeps the connection to itself while it is busy.
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        if !dictation.busy { phone.refreshQuestions() }
        do { try await Task.sleep(for: .seconds(2)) } catch { break }
      }
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(4)) } catch { break }
        dictation.refresh()
      }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .active {
        phone.browse()
        dictation.refresh()
      } else {
        phone.suspend(background: phase == .background)
        dictation.cancel()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notice in
      if notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue,
         dictation.phase == .listening {
        dictation.cancel("Recording interrupted.")
      }
    }
    .sensoryFeedback(.impact(weight: .light), trigger: dictation.feedbackCount)
    .sensoryFeedback(.warning, trigger: dictation.cancelCount)
  }

  private var dictationMac: PhoneWhip.Mac? {
    guard phone.paired, let mac = phone.selected, mac.supportsDictation else { return nil }
    return mac
  }

  private var controller: some View {
    GeometryReader { geometry in
      ZStack {
        pal.base.ignoresSafeArea()
        RadialGradient(colors: [(stampHolding ? pal.red : pal.mauve).opacity(holding || stampHolding ? 0.28 : 0.12), .clear],
                       center: .center, startRadius: 0, endRadius: 270)
          .ignoresSafeArea().accessibilityHidden(true)

        if !dictation.busy {
          sessionFigures(in: geometry.size)
            .opacity(openCard == nil ? 1 : 0.15)
        }
        // The open question stays in place (hidden) while dictating, so a dictated answer reaches it.
        if let id = openCard, let card = phone.cards.first(where: { $0.session == id }) {
          PhoneQuestionCard(card: card, dismiss: { openCard = nil }, issue: phone.answerIssue, pal: pal,
                            dictated: $dictatedAnswer) {
            decision, answers in phone.answer(card, decision: decision, answers: answers)
          }
          .id(card.id)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
          .frame(maxWidth: 520, maxHeight: .infinity)
          .opacity(dictation.busy ? 0 : 1)
          .allowsHitTesting(!dictation.busy)
        }
        if dictation.busy {
          dictationPanel
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
      }
    }
    .overlay {
      if let id = reading, let session = dictation.sessions.first(where: { $0.id == id }), let last = session.last {
        VStack(alignment: .leading, spacing: 10) {
          Text(session.title.isEmpty ? session.folder : "\(session.folder) · \(session.title)")
            .font(.footnote.weight(.semibold)).foregroundStyle(pal.subtext).lineLimit(1)
          ScrollView {
            Text(last).font(.body).foregroundStyle(pal.text)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(20)
        .background(pal.mantle, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(pal.mauve.opacity(0.5), lineWidth: 1.5))
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture { reading = nil }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap to close")
        .transition(.opacity)
      }
    }
    .overlay {
      if let id = menuFigure, let figure = figures.first(where: { $0.id == id }) {
        SessionMenuOverlay(
          figure: SessionFigure(size: 120, look: figure.look, state: figure.state, dizzyUntil: nil, pal: pal),
          name: figure.title.isEmpty ? figure.folder : "\(figure.folder) · \(figure.title)",
          options: menuOptions(figure), aim: menuAim, pal: pal,
          pick: { pick($0, on: id) }, close: closeMenu)
        .transition(.opacity)
      }
    }
    .sensoryFeedback(.impact(weight: .medium), trigger: menuFigure) { _, open in open != nil }
    .sensoryFeedback(.selection, trigger: menuAim)
    .sensoryFeedback(.impact, trigger: reading) { _, now in now != nil }
    .overlay(alignment: .topTrailing) {
      macMenu
        .frame(width: 52)
        .padding(.trailing, 20)
        .padding(.top, 8)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { controls }
    // The agent archives itself in Claude Desktop once it is idle.
    .confirmationDialog("Ask this session to archive itself?",
                        isPresented: Binding(get: { archiveTarget != nil }, set: { if !$0 { archiveTarget = nil } }),
                        titleVisibility: .visible, presenting: archiveTarget) { session in
      Button("Archive") { phone.archive(session: session) }
      Button("Cancel", role: .cancel) {}
    }
    .sensoryFeedback(.success, trigger: phone.archiveCount)
    .onChange(of: openCard) { _, open in
      dictation.answerHandler = open == nil ? nil : { text in dictatedAnswer = text }
    }
    .onChange(of: phone.cards.map(\.session)) { _, sessions in
      if let open = openCard, !sessions.contains(open) { openCard = nil }
    }
    .onDisappear {
      phone.arm(false)
      phone.releaseStamp()
      dictation.cancel()
    }
  }

  private func mascot(size: CGFloat) -> some View {
    let accent = pal.mauve
    let filled = false
    return ZStack {
      Circle().fill(accent.opacity(filled ? 0.28 : 0.10))
      Circle().strokeBorder(accent.opacity(holding || stampHolding || filled ? 0.9 : 0.3), lineWidth: filled ? 3 : 1.5)
      Circle().strokeBorder(accent.opacity(0.14), lineWidth: 1).padding(10)
      Image("CompanionMascot")
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .padding(size * 0.17)
        .scaleEffect((holding || stampHolding) && !reduceMotion ? 1.08 : 1)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.17), value: holding || stampHolding)
  }

  private struct Figure: Identifiable {
    let id: String
    let folder: String
    /// False for a session that has a question waiting but has not checked in for dictation.
    let canDictate: Bool
    /// waiting, working or idle.
    let state: String
    let look: PhoneLook
    let title: String
    var parent: String?
    /// Text under the figure, set when the folder name alone would not tell two sessions apart.
    var tag = ""
  }

  private var figures: [Figure] {
    var list = dictationMac == nil ? [] : dictation.sessions.map {
      Figure(id: $0.id, folder: $0.folder, canDictate: true, state: $0.state ?? "idle", look: PhoneLook($0.cwd ?? $0.folder),
             title: $0.title, parent: $0.parent)
    }
    for card in phone.cards where !list.contains(where: { $0.id == card.session }) {
      list.append(Figure(id: card.session, folder: card.folder, canDictate: false, state: "waiting", look: PhoneLook(card.cwd ?? card.folder), title: card.title))
    }
    // Two sessions in one project: tell them apart by title, and by look (the session id joins the hash).
    let cwds = Dictionary(grouping: dictation.sessions, by: { $0.cwd ?? $0.folder })
    return list.map { figure in
      var figure = figure
      let twins = list.filter { $0.folder == figure.folder }.count > 1
      if twins {
        let cwd = dictation.sessions.first { $0.id == figure.id }.map { $0.cwd ?? $0.folder } ?? figure.folder
        if (cwds[cwd]?.count ?? 0) > 1 { figure = Figure(id: figure.id, folder: figure.folder, canDictate: figure.canDictate, state: figure.state, look: PhoneLook(cwd + figure.id), title: figure.title, parent: figure.parent) }
        figure.tag = figure.title.isEmpty ? "#" + figure.id.prefix(4) : figure.title
      } else {
        figure.tag = figure.title
      }
      return figure
    }
  }

  /// Main sessions with the sessions nested under them (side chats, forks, worktree sessions), in list order.
  private func families(_ list: [Figure]) -> [(root: Figure, nested: [Figure])] {
    let ids = Set(list.map(\.id))
    func rootID(of figure: Figure) -> String {
      var current = figure
      var seen: Set<String> = [figure.id]
      while let parent = current.parent, ids.contains(parent), !seen.contains(parent),
            let next = list.first(where: { $0.id == parent }) {
        seen.insert(parent)
        current = next
      }
      return current.id
    }
    return list.filter { rootID(of: $0) == $0.id }.map { root in
      (root, list.filter { $0.id != root.id && rootID(of: $0) == root.id })
    }
  }

  /// A session is selected when picked, or when it is the only one. Whip and stamp need one; dictation does not.
  private var sessionSelected: Bool {
    guard dictationMac != nil else { return false }
    guard let target = dictation.target else { return false }
    return dictation.sessions.contains { $0.id == target }
  }

  /// The state of the session that whip and stamp would act on.
  private var selectedState: String? {
    guard sessionSelected else { return nil }
    return dictation.sessions.first { $0.id == selectedID }?.state
  }

  /// Pull down: look for sessions that started since, and for their questions.
  private func reload() async {
    dictation.refresh(manual: true)
    phone.refreshQuestions()
    for _ in 0..<30 {
      try? await Task.sleep(for: .milliseconds(100))
      if !dictation.loading { break }
    }
  }

  private var selectedID: String? { sessionSelected ? dictation.target : nil }

  private func tap(_ figure: Figure) {
    if phone.cards.contains(where: { $0.session == figure.id }) {
      if figure.canDictate, dictation.target != figure.id { dictation.select(figure.id) }
      openCard = openCard == figure.id ? nil : figure.id
    } else if figure.canDictate {
      dictation.select(dictation.target == figure.id ? nil : figure.id)
    }
  }

  private func figureButton(_ figure: Figure, side: CGFloat) -> some View {
    let chosen = dictation.target == figure.id
    let nested = figure.parent != nil
    return VStack(spacing: 6) {
      do {
        SessionFigure(size: side, look: figure.look, state: figure.state, dizzyUntil: phone.hurt[figure.id], pal: pal,
                      ring: chosen ? pal.green : nil, filled: chosen)
        VStack(spacing: 1) {
          // A nested session is named by its own title; the folder is its parent's.
          Text(nested && !figure.title.isEmpty ? figure.title : figure.folder)
            .font(nested ? .caption2.weight(.semibold) : .footnote.weight(.semibold)).lineLimit(1)
          if !nested, !figure.tag.isEmpty { Text(figure.tag).font(.caption2).lineLimit(1).opacity(0.75) }
          if nested, figure.title.isEmpty { Text(figure.tag).font(.caption2).lineLimit(1).opacity(0.75) }
        }
        .foregroundStyle(chosen ? pal.green : pal.subtext)
        .frame(width: side + 8)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { if !dictation.busy { tap(figure) } }
    // Hold a session for its menu. Swipe toward an option and let go to pick it, or let go and tap one.
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.45)
        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
        .onChanged { value in
          guard case .second(true, let drag) = value else { return }
          if menuFigure == nil { openMenu(figure) }
          if let drag { aimMenu(drag.translation, options: menuOptions(figure)) }
        }
        .onEnded { value in
          guard case .second(true, _) = value else { return }
          if let aim = menuAim, menuFigure == figure.id { pick(aim, on: figure.id) }
          menuAim = nil
        }
    )
    .accessibilityActions {
      ForEach(menuOptions(figure), id: \.title) { option in
        Button(option.title) { pick(option.direction, on: figure.id) }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(figure.folder)
    .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
  }

  private func menuOptions(_ figure: Figure) -> [SessionMenuOverlay.Option] {
    var options: [SessionMenuOverlay.Option] = []
    if dictation.sessions.first(where: { $0.id == figure.id })?.last != nil {
      options.append(.init(direction: .left, symbol: "text.bubble.fill", title: "Last message", tint: pal.mauve))
    }
    if figure.canDictate {
      options.append(.init(direction: .up, symbol: "archivebox.fill", title: "Archive", tint: pal.blue))
      if dictationMac?.supportsSideChat == true {
        options.append(.init(direction: .right, symbol: "bubble.left.and.text.bubble.right.fill", title: "Side chat", tint: pal.teal))
      }
    }
    return options
  }

  private func openMenu(_ figure: Figure) {
    let options = menuOptions(figure)
    guard !dictation.busy, !options.isEmpty else { return }
    menuAim = nil
    menuFigure = figure.id
  }

  /// A swipe of 50 points from where the finger was held aims at the option that way.
  private func aimMenu(_ move: CGSize, options: [SessionMenuOverlay.Option]) {
    let has = { (d: SessionMenuDirection) in options.contains { $0.direction == d } }
    var next: SessionMenuDirection?
    if abs(move.width) >= abs(move.height) {
      if move.width > 50, has(.right) { next = .right } else if move.width < -50, has(.left) { next = .left }
    } else if move.height < -50, has(.up) { next = .up }
    if next != menuAim { menuAim = next }
  }

  private func closeMenu() {
    menuAim = nil
    menuFigure = nil
  }

  private func pick(_ direction: SessionMenuDirection, on session: String) {
    closeMenu()
    switch direction {
    case .left: reading = session
    case .up: archiveTarget = session
    case .right: dictation.askSideChat(session)
    }
  }

  /// One Claude for no session or one session. With several, each session is its own Claude: tap one to select it,
  /// or to open its question.
  @ViewBuilder private func sessionFigures(in size: CGSize) -> some View {
    let list = figures
    if list.count < 2 {
      let side = min(size.width * 0.61, size.height * 0.55, 280)
      ScrollView {
        Group {
          if let only = list.first {
            // The project it is working on, under the figure.
            figureButton(only, side: side)
          } else {
            mascot(size: side)
          }
        }
        .frame(maxWidth: .infinity, minHeight: size.height)
      }
      .scrollBounceBehavior(.always)
      // A swipe in the long-press menu picks an option; it must not drag the list too.
      .scrollDisabled(menuFigure != nil)
      .refreshable { await reload() }
    } else {
      let groups = families(list)
      let nests = groups.contains { !$0.nested.isEmpty }
      let columns = nests || groups.count > 4 ? (groups.count > 1 && !nests ? 3 : 2) : 2
      let side = min((size.width - 40 - CGFloat(columns - 1) * 16) / CGFloat(columns), 170)
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns), spacing: 24) {
          ForEach(groups, id: \.root.id) { group in
            VStack(spacing: 0) {
              figureButton(group.root, side: side)
              if !group.nested.isEmpty {
                // A short branch from the main session down to the sessions nested under it.
                Rectangle().fill(pal.overlay.opacity(0.6)).frame(width: 2, height: 12)
                let small = max(52, side * 0.46)
                let perRow = max(1, Int((side + 24) / (small + 8)))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(small), spacing: 8, alignment: .top), count: min(perRow, group.nested.count)), spacing: 10) {
                  ForEach(group.nested) { figure in figureButton(figure, side: small) }
                }
                .padding(.top, 8)
                .overlay(alignment: .top) {
                  Rectangle().fill(pal.overlay.opacity(0.6)).frame(height: 2).padding(.horizontal, small / 2)
                }
              }
            }
            .frame(maxWidth: .infinity)
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        // Clear of the Mac button in the corner.
        .padding(.top, 72)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.always)
      // A swipe in the long-press menu picks an option; it must not drag the list too.
      .scrollDisabled(menuFigure != nil)
      .refreshable { await reload() }
      // A tap on empty space deselects; the figures are buttons, so they take their own taps first.
      .background {
        Color.clear.contentShape(Rectangle()).onTapGesture { if !dictation.busy { dictation.select(nil) } }
      }
      .sensoryFeedback(.selection, trigger: dictation.target)
    }
  }

  /// A big, rounded thumb target showing only an icon.
  private func tile(_ symbol: String, fill: Color, ink: Color? = nil, height: CGFloat = 68, size: CGFloat = 26) -> some View {
    Image(systemName: symbol)
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(ink ?? pal.onAccent)
      .frame(maxWidth: .infinity, minHeight: height)
      .background(fill, in: RoundedRectangle(cornerRadius: height > 80 ? 30 : 22))
      .contentShape(RoundedRectangle(cornerRadius: height > 80 ? 30 : 22))
  }

  private var macMenu: some View {
    Menu {
      if let mac = phone.selected { Text(mac.name) }
      Button("Choose Another Mac", systemImage: "laptopcomputer") { phone.chooseAnotherMac() }
    } label: {
      tile("laptopcomputer", fill: pal.surface1, ink: pal.text, height: 52, size: 20)
    }
    .disabled(dictation.busy)
    .accessibilityLabel("Mac")
    // The agent archives itself in Claude Desktop once it is idle.
  }

  private var dictationPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch dictation.phase {
      case .idle:
        EmptyView()
      case .preparing, .rewriting, .sending:
        ProgressView().tint(pal.mauve)
      case .finishing:
        // Transcribing the whole recording; it gives up when this runs out.
        HStack(spacing: 12) {
          ProgressView().tint(pal.mauve)
          if let deadline = dictation.transcribeDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
              Text("\(max(0, Int(ceil(deadline.timeIntervalSince(timeline.date)))))")
                .font(.system(size: 34, weight: .bold).monospacedDigit()).foregroundStyle(pal.subtext)
            }
          }
        }
      case .listening:
        HStack(spacing: 12) {
          // Flat while it hears nothing, moving with your voice.
          TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let level = CGFloat(dictation.audioLevel)
            HStack(spacing: 4) {
              ForEach(0..<7, id: \.self) { bar in
                let wobble = 0.55 + 0.45 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 9 + Double(bar) * 1.3))
                Capsule().fill(pal.red).frame(width: 5, height: 6 + 34 * level * wobble)
              }
            }
            .frame(height: 40)
          }
          if let since = dictation.listeningSince {
            TimelineView(.periodic(from: since, by: 1)) { timeline in
              let seconds = max(0, Int(timeline.date.timeIntervalSince(since)))
              Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.footnote.monospacedDigit()).foregroundStyle(pal.subtext)
            }
          }
        }
      case .releaseToReview:
        Image(systemName: "waveform").font(.system(size: 34, weight: .bold)).foregroundStyle(pal.text)
      case .review(let deadline):
        TimelineView(.periodic(from: deadline.addingTimeInterval(-PhoneDictation.reviewSeconds), by: 1)) { timeline in
          let remaining = max(0, Int(ceil(deadline.timeIntervalSince(timeline.date))))
          HStack(spacing: 10) {
            Image(systemName: "paperplane.fill")
            Text("\(remaining)").monospacedDigit()
          }
          .font(.system(size: 34, weight: .bold)).foregroundStyle(pal.green)
        }
      }
      Text(dictation.previewTarget).font(.subheadline).foregroundStyle(pal.subtext)
      if !dictation.draft.isEmpty {
        ScrollView {
          Text(dictation.draft)
            .font(.title3)
            .foregroundStyle(pal.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .defaultScrollAnchor(dictation.phase == .listening ? .bottom : .top)
      }
    }
    .frame(maxWidth: 520, alignment: .leading)
    .padding(18)
    .background(pal.mantle, in: RoundedRectangle(cornerRadius: 26))
  }

  private var microphone: some View {
    tile(micHolding ? "waveform" : "mic.fill", fill: pal.blue, height: 88, size: 34)
      .opacity(dictation.canRecord || micHolding ? 1 : 0.4)
      .scaleEffect(micHolding && !reduceMotion ? 0.96 : 1)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel("Hold to dictate")
      .gesture(DragGesture(minimumDistance: 0)
        .updating($micHolding) { _, held, _ in held = true }
        .onChanged { _ in
          guard !micPressStarted, scenePhase == .active, !holding, !stampHolding, !phone.sending,
                dictation.canRecord else { return }
          micPressStarted = true
          dictation.start()
        }
        .onEnded { _ in
          guard micPressStarted else { return }
          micPressStarted = false
          dictation.release()
        })
      .onChange(of: micHolding) { _, held in
        guard !held else { return }
        DispatchQueue.main.async {
          guard !micHolding, micPressStarted else { return }
          micPressStarted = false
          dictation.cancel()
        }
      }
  }

  private var controls: some View {
    VStack(spacing: 12) {
      if let issue = dictation.message ?? phone.controlIssue {
        Text(issue).font(.footnote).foregroundStyle(pal.subtext)
          .multilineTextAlignment(.center)
      }
      if case .review = dictation.phase {
        // Reviewing the dictation: these take the place of whip and stamp.
        HStack(spacing: 12) {
          Button { dictation.cancel("Dictation cancelled.") } label: {
            tile("xmark", fill: pal.red, height: 88, size: 34)
          }
          Button { dictation.approve() } label: {
            tile("checkmark", fill: pal.green, height: 88, size: 34)
          }
        }
        .buttonStyle(.plain)
      } else if dictationMac != nil {
        // Always in place so nothing moves; greyed out until a session is picked.
        HStack(spacing: 12) {
          if phone.canHold {
            tile(holding ? "bolt.fill" : "lasso", fill: holding ? pal.green : pal.mauve, height: 88, size: 34)
              .accessibilityAddTraits(.isButton)
              .accessibilityLabel("Hold to arm the whip")
              .opacity(sessionSelected ? 1 : 0.35)
              .disabled(dictation.busy || micHolding)
              .gesture(DragGesture(minimumDistance: 0).updating($holding) { _, held, _ in held = true })
              .onChange(of: holding) { _, held in
                let go = held && sessionSelected && !stampHolding && !dictation.busy && !micHolding && scenePhase == .active
                // Working: hurry up. Waiting on a prompt: approve it. Idle: go ahead with what it proposed.
                if go, let session = selectedID {
                  let kind: PhoneWhip.Steer = switch selectedState {
                  case "working": .speedUp
                  case "waiting": .approve
                  default: .goAhead
                  }
                  phone.armSteer(true, session: session, kind: kind)
                } else {
                  phone.arm(false)
                  phone.armSteer(false, session: "")
                }
              }
              .onDisappear { phone.arm(false) }
          }
          stampControl
        }
      }
      if dictationMac != nil { microphone }
    }
    .frame(maxWidth: 520)
    .padding(.horizontal, 20)
    .padding(.top, 14)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity)
    .background(pal.mantle)
  }

  /// Hold and flick: "do this differently". No short press. Works on any selected session.
  @ViewBuilder private var stampControl: some View {
    do {
      let session = selectedID ?? ""
      tile(stampHolding ? "hand.point.down.fill" : "seal.fill", fill: pal.red, height: 88, size: 34)
        .opacity(sessionSelected ? 1 : 0.35)
        .scaleEffect(stampHolding && !reduceMotion ? 0.96 : 1)
        .disabled(holding || micHolding || dictation.busy || scenePhase != .active)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Stamp")
        .gesture(DragGesture(minimumDistance: 0).updating($stampHolding) { _, held, _ in held = true })
        .onChange(of: stampHolding) { _, held in
          let go = held && sessionSelected && !holding && !dictation.busy && !micHolding && scenePhase == .active
          phone.armSteer(go, session: session, kind: .change)
        }
        .sensoryFeedback(.success, trigger: phone.changeCount)
        .onDisappear { phone.armSteer(false, session: "") }
    }
  }

  private var pairing: some View {
    VStack(spacing: 14) {
      Spacer()
      if let mac = phone.selected {
        Text(mac.name).font(.title2.weight(.semibold)).foregroundStyle(pal.text)
        if let match = phone.match {
          Text(match)
            .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(pal.mauve)
            .accessibilityLabel("Pairing number \(match)")
        } else if phone.sending {
          ProgressView().tint(pal.mauve)
        }
      } else if phone.macs.isEmpty {
        ProgressView().tint(pal.mauve).accessibilityLabel(phone.status)
      } else {
        ScrollView {
          VStack(spacing: 12) {
            ForEach(phone.macs) { mac in
              Button { phone.choose(mac) } label: {
                HStack {
                  Image(systemName: "laptopcomputer")
                  Text(mac.name).font(.title3.weight(.semibold))
                  Spacer()
                }
                .foregroundStyle(pal.text)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 76)
                .background(pal.surface0, in: RoundedRectangle(cornerRadius: 24))
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(maxHeight: 360)
      }
      Spacer()
    }
    .padding(.horizontal, 20)
    .frame(maxWidth: 520)
    .frame(maxWidth: .infinity)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if phone.selected != nil {
        HStack(spacing: 12) {
          if phone.sending {
            Button { phone.chooseAnotherMac() } label: { tile("xmark", fill: pal.red) }
          } else {
            Button { phone.retry() } label: { tile("arrow.clockwise", fill: pal.blue) }
            Button { phone.pairAgain() } label: { tile("link", fill: pal.mauve) }
            Button { phone.chooseAnotherMac() } label: { tile("laptopcomputer", fill: pal.surface1, ink: pal.text) }
          }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(pal.mantle)
      }
    }
  }
}
