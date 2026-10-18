import Foundation
import Observation

@MainActor @Observable final class ChatStore {
  private(set) var messages: [ChatMessage] = []
  private(set) var connected = false
  private(set) var pinned: ChatMessage?
  private(set) var hasSession = DestinyAccount.hasSession
  private(set) var identity: String?
  private(set) var account: ChatUser?
  private(set) var users: [String: ChatUser] = [:]
  private(set) var poll: ChatPoll?
  private(set) var subOnly = 0
  private(set) var mutedUntil: Date?
  private(set) var banned = false
  private(set) var unreadWhispers: [String: Int] = [:]
  private(set) var conversations: [String: [ChatMessage]] = [:]
  private(set) var conversationNames: [String: String] = [:]
  private(set) var conversationPreviews: [String: String] = [:]
  private(set) var moreConversations = false
  private(set) var loadingConversations = false
  private var conversationCursor: (timestamp: String, id: Int)?
  private var loadedHistory: [String: Int] = [:]
  private var privateGeneration = 0
  private var conversationOwner: String?
  private(set) var votePending = false
  private var voteTimeout: Task<Void, Never>?
  var activeRecipient: String?
  var filter = ""
  var watchingFocus = false
  var hideUnfocused = false
  var pollVisible = true
  var requestedSource: StreamSource?
  var selectedSource: StreamSource?
  var requestedReply: String?
  var requestedProfile: ChatUser?
  var dismissedPin = UserDefaults.standard.string(forKey: "dismissedPin")
  private(set) var assetRevision = 0
  private(set) var assetCacheKey: String?
  private(set) var settingsRevision = 0
  func settingsChanged() { settingsRevision += 1 }
  private var replayingHistory = false
  private(set) var paidEvents: [ChatMessage] = []
  private(set) var spotlights: [String: ChatMessage] = [:]
  private var eventExpiry: Task<Void, Never>?
  var highlighted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "highlightedUsers") ?? [])
  private var userRevision = 0
  static let tagColorNames = ["green", "yellow", "orange", "red", "purple", "blue", "sky", "lime", "pink", "black"]
  var tagColors: [String: String] = UserDefaults.standard.dictionary(forKey: "chatTagColors") as? [String: String] ?? [:]
  var tags: [String: String] = UserDefaults.standard.dictionary(forKey: "chatTags") as? [String: String] ?? [:]
  private var pollExpiry: Task<Void, Never>?
  private var lastWhisper: String?
  var lastWhisperRecipient: String? { lastWhisper }
  var renderingRevision: Int {
    var hasher = Hasher()
    hasher.combine(selectedSource?.id)
    hasher.combine(watchingFocus)
    hasher.combine(hideUnfocused)
    hasher.combine(identity); hasher.combine(highlighted); hasher.combine(userRevision)
    for key in tagColors.keys.sorted() { hasher.combine(key); hasher.combine(tagColors[key]) }
    for key in tags.keys.sorted() { hasher.combine(key); hasher.combine(tags[key]) }
    hasher.combine(spotlights.keys.sorted())
    return hasher.finalize()
  }
  private var pendingWhispers: [(nick: String, text: String)] = []
  private var retryAllowed = true
  private var muteExpiry: Task<Void, Never>?
  var canSend: Bool {
    connected && identity != nil && !banned && (mutedUntil == nil || mutedUntil! <= Date())
      && (activeRecipient != nil || subOnly == 0 || account?.privileged == true || (account?.tier ?? 0) >= subOnly)
  }
  var visibleMessages: [ChatMessage] {
    let source = activeRecipient.flatMap { conversations[$0.lowercased()] } ?? (activeRecipient == nil ? messages : [])
    let defaults = UserDefaults.standard
    let harshIgnore = !ignored.isEmpty && defaults.bool(forKey: "harshIgnore")
    let removedMessages = ChatPreferences.removedMessages
    let showWhispers = activeRecipient != nil || defaults.bool(forKey: "showWhispersInChat")
    let focusMentions = defaults.bool(forKey: "focusChatMentions")
    let highlightMentions = !defaults.bool(forKey: "disableMentionHighlight")
    let rules = ChatPreferences.textRules
    let matcher = identity.map { Self.mentionMatcher($0) }
    let hiding = hideUnfocused && activeRecipient == nil
    return source.filter { message in
      !ignored.contains(message.nick.lowercased())
        && (!harshIgnore || !message.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).contains(where: { ignored.contains($0.lowercased()) }))
        && (!message.removed || removedMessages != 0)
        && (showWhispers || !message.whisper)
        && (filter.isEmpty || message.nick.localizedCaseInsensitiveContains(filter) || message.text.localizedCaseInsensitiveContains(filter))
        && (!focusMentions || matcher == nil || matcher?.matches(message.text) == true)
        && ChatVisibility.includes(message, sameStream: isWatchingSame(message),
          highlighted: ChatVisibility.highlightedAuthor(message, highlights: highlighted)
            || rules.highlighted(message.text) || (highlightMentions && matcher?.matches(message.text) == true),
          hideUnfocused: hiding, watchingFocus: watchingFocus)
    }
  }
  func isWatchingSame(_ message: ChatMessage) -> Bool {
    ChatVisibility.watchingSame(message, users: users, selected: selectedSource)
  }
  func isHighlighted(_ message: ChatMessage, rules: ChatTextRules? = nil) -> Bool {
    ChatVisibility.highlightedAuthor(message, highlights: highlighted) || (rules ?? ChatPreferences.textRules).highlighted(message.text)
      || (!UserDefaults.standard.bool(forKey: "disableMentionHighlight")
        && identity.map { Self.mentions($0, in: message.text) } == true)
  }
  private static var cachedMentionMatcher: ChatMentionMatcher?
  private static func mentionMatcher(_ nick: String) -> ChatMentionMatcher {
    if let cachedMentionMatcher, cachedMentionMatcher.nick == nick { return cachedMentionMatcher }
    let matcher = ChatMentionMatcher(nick)
    cachedMentionMatcher = matcher
    return matcher
  }
  static func mentions(_ nick: String, in text: String) -> Bool { mentionMatcher(nick).matches(text) }
  var error: String?
  var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredUsers") ?? [])
  private let connection = DestinySocket()
  private var buffer = MessageBuffer(capacity: {
    let saved = UserDefaults.standard.integer(forKey: "maximumChatMessages")
    return saved == 0 ? 1000 : min(5000, max(100, saved))
  }())
  private var pending: [ChatMessage] = []
  private var worker: Task<Void, Never>?
  private var publisher: Task<Void, Never>?
  private var active = false
  private var stopping = false
  private var desiredActive = false

  func start() {
    desiredActive = true
    guard !active, !stopping else { return }
    active = true
    retryAllowed = true
    scheduleEvents()
    worker = Task { [weak self] in
      var failures = 0
      while !Task.isCancelled {
        guard let connection = self?.connection else { return }
        self?.identity = nil
        self?.account = nil
        self?.users = [:]
        self?.banned = false
        self?.subOnly = 0
        self?.pendingWhispers.removeAll()
        if DestinyAccount.hasSession { _ = try? await DestinyAccount.request("/api/chat/me") }
        await connection.connect()
        let opened = Date()
        do {
          while !Task.isCancelled {
            let event = try await connection.receive()
            guard !Task.isCancelled else { break }
            if self?.connected != true {
              self?.connected = true
            }
            if Date().timeIntervalSince(opened) > 5 { failures = 0 }
            if case .ping(let body) = event {
              try await connection.send("PONG \(body)")
            } else {
              self?.consume(event)
            }
          }
        } catch {
          // Reconnect with bounded backoff below.
        }
        self?.connected = false
        self?.pollExpiry?.cancel()
        self?.poll?.ended = true
        await connection.disconnect()
        guard !Task.isCancelled, self?.retryAllowed == true else { break }
        failures = min(failures + 1, 6)
        let seconds = min(60.0, pow(2.0, Double(failures))) + Double.random(in: 0...1)
        do { try await Task.sleep(for: .seconds(seconds)) } catch { break }
      }
    }
  }

  func stop() async {
    desiredActive = false
    guard !stopping else { return }
    stopping = true
    worker?.cancel()
    publisher?.cancel()
    pollExpiry?.cancel()
    eventExpiry?.cancel()
    voteTimeout?.cancel()
    votePending = false
    poll?.ended = true
    await connection.disconnect()
    await worker?.value
    worker = nil
    publisher = nil
    flush()
    connected = false
    identity = nil
    account = nil
    pendingWhispers.removeAll()
    active = false
    stopping = false
    if desiredActive { start() }
  }

  func restart() async {
    await stop()
    resetPrivateMessages()
    hasSession = DestinyAccount.hasSession
    start()
  }

  func send(_ text: String, recipient: String? = nil) async -> Bool {
    do {
      let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if recipient == nil, text.hasPrefix("/"), !text.hasPrefix("/me ") {
        return try await command(text)
      }
      guard hasSession else { throw ChatInputError.loginRequired }
      guard connected else { throw ChatInputError.disconnected }
      guard identity != nil else { throw ChatInputError.loginRequired }
      guard !banned, mutedUntil == nil || mutedUntil! <= Date() else {
        throw ChatInputError.invalidCommand(banned ? "You are banned from chat." : "You are temporarily muted.")
      }
      if recipient == nil, let number = Int(text), let poll,
        !poll.ended, (1...poll.options.count).contains(number) {
        return await vote(number)
      }
      let frame = try ChatProtocol.encode(text: text, recipient: recipient)
      if let recipient { pendingWhispers.append((recipient, text)) }
      do { try await connection.send(frame) }
      catch {
        if let recipient, let index = pendingWhispers.lastIndex(where: { $0.nick == recipient && $0.text == text }) {
          pendingWhispers.remove(at: index)
        }
        throw error
      }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func transmit(_ command: String, _ payload: [String: Any]) async throws {
    guard connected else { throw ChatInputError.disconnected }
    guard identity != nil else { throw ChatInputError.loginRequired }
    try await connection.send(ChatProtocol.frame(command, payload))
  }
  func vote(_ option: Int) async -> Bool {
    guard let poll, !poll.ended, poll.ends > Date(), poll.canVote,
      !votePending, (1...poll.options.count).contains(option) else { error = "You cannot vote in this poll."; return false }
    votePending = true
    do {
      try await transmit("CASTVOTE", ["vote": String(option)])
      voteTimeout?.cancel()
      voteTimeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        self?.votePending = false
      }
      return true
    } catch { votePending = false; self.error = error.localizedDescription; return false }
  }
  func dismissPinned() {
    dismissedPin = pinned?.id
    UserDefaults.standard.set(dismissedPin, forKey: "dismissedPin")
  }
  func unignore(_ nick: String) {
    ignored.remove(nick.lowercased())
    UserDefaults.standard.set(Array(ignored).sorted(), forKey: "ignoredUsers")
  }
  func clearMessages() { pending.removeAll(); buffer.clear(); messages = [] }
  func setMaximumMessages(_ count: Int) {
    let retained = buffer.messages
    buffer = MessageBuffer(capacity: min(5000, max(100, count)))
    buffer.append(retained)
    messages = buffer.messages
    UserDefaults.standard.set(buffer.capacity, forKey: "maximumChatMessages")
  }
  func highlight(_ nick: String, enabled: Bool) {
    if enabled { highlighted.insert(nick.lowercased()) } else { highlighted.remove(nick.lowercased()) }
    UserDefaults.standard.set(Array(highlighted).sorted(), forKey: "highlightedUsers")
  }
  func tag(_ nick: String, text: String?, color: String? = nil) {
    let key = nick.lowercased()
    tags[key] = text
    tagColors[key] = text == nil ? nil : color ?? tagColors[key] ?? "blue"
    UserDefaults.standard.set(tags, forKey: "chatTags")
    UserDefaults.standard.set(tagColors, forKey: "chatTagColors")
  }
  private func remember(_ user: ChatUser) {
    guard users[user.id] != user else { return }
    userRevision += 1
    users[user.id] = user
  }
  func system(_ text: String) { enqueue([ChatMessage(payload: ["data": text], kind: "SYSTEM")]) }
  func openConversation(_ nick: String) {
    activeRecipient = nick
    conversationNames[nick.lowercased()] = nick
    unreadWhispers[nick.lowercased()] = 0
    if DestinyAccount.hasSession {
      Task { await loadConversation(nick) }
    }
  }
  func loadConversation(_ nick: String, older: Bool = false) async {
    let version = privateGeneration
    let escaped = nick.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
    do {
      let offset = older ? loadedHistory[nick.lowercased(), default: 0] : 0
      let data = try await DestinyAccount.request("/api/messages/usr/\(escaped)/inbox?s=\(offset)")
      guard privateGeneration == version else { return }
      guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
      loadedHistory[nick.lowercased()] = offset + rows.count
      let history = rows.reversed().map { row -> ChatMessage in
        var payload: [String: Any] = ["nick": row["from"] as? String ?? nick, "data": row["message"] as? String ?? ""]
        if let number = row["timestamp"] as? Double { payload["timestamp"] = number }
        else if let date = row["timestamp"] as? String, let parsed = ISO8601DateFormatter().date(from: date) {
          payload["timestamp"] = parsed.timeIntervalSince1970 * 1000
        }
        payload["messageid"] = row["messageId"] ?? row["messageid"] ?? row["id"]
        return ChatMessage(payload: payload, whisper: true, recipient: nick)
      }
      let existing = conversations[nick.lowercased()] ?? []
      var seen: Set<String> = []
      conversations[nick.lowercased()] = Array((history + existing).filter { seen.insert($0.id).inserted }.suffix(1000))
    } catch { if privateGeneration == version { self.error = error.localizedDescription } }
  }
  func loadConversations(more: Bool = false) async {
    guard DestinyAccount.hasSession, !loadingConversations else { return }
    loadingConversations = true
    let version = privateGeneration
    defer { if privateGeneration == version { loadingConversations = false } }
    do {
      var path = "/api/messages/conversations"
      if more, let cursor = conversationCursor,
        let timestamp = cursor.timestamp.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?#+"))) {
        path += "?last-timestamp=\(timestamp)&last-id=\(cursor.id)"
      }
      let data = try await DestinyAccount.request(path)
      guard privateGeneration == version else { return }
      guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        reply["success"] as? Bool == true, let payload = reply["data"] as? [String: Any],
        let rows = payload["results"] as? [[String: Any]] else {
        throw ChatInputError.invalidCommand("Destiny.gg could not load conversations.")
      }
      for row in rows {
        guard let nick = row["username"] as? String else { continue }
        let key = nick.lowercased()
        conversationNames[key] = nick
        conversationPreviews[key] = row["lastMessage"] as? String
        if activeRecipient?.lowercased() != key { unreadWhispers[key] = row["unread"] as? Int ?? 0 }
      }
      moreConversations = payload["more"] as? Bool ?? false
      if let cursor = payload["nextPageOffset"] as? [String: Any], let id = cursor["id"] as? Int,
        let timestamp = cursor["timestamp"] as? String { conversationCursor = (timestamp, id) }
      else { conversationCursor = nil; moreConversations = false }
    } catch { if privateGeneration == version { self.error = error.localizedDescription } }
  }
  private func resetPrivateMessages() {
    privateGeneration += 1
    conversations.removeAll(); conversationNames.removeAll(); conversationPreviews.removeAll()
    unreadWhispers.removeAll(); loadedHistory.removeAll(); pendingWhispers.removeAll()
    activeRecipient = nil; lastWhisper = nil; conversationCursor = nil
    moreConversations = false; loadingConversations = false
    pending.removeAll { $0.whisper }; buffer.removeWhispers(); messages = buffer.messages
    ChatPreferences.clearNotifications()
  }
  private func addWhisper(_ message: ChatMessage, conversation: String, incoming: Bool) {
    let key = conversation.lowercased()
    conversationNames[key] = conversation
    conversationPreviews[key] = message.text
    var items = conversations[key] ?? []
    guard !items.contains(where: { $0.id == message.id }) else { return }
    items.append(message)
    conversations[key] = Array(items.suffix(1000))
    if incoming {
      lastWhisper = conversation
      if activeRecipient?.lowercased() != key { unreadWhispers[key, default: 0] += 1 }
      else if let messageID = message.messageID, DestinyAccount.hasSession {
        Task { _ = try? await DestinyAccount.request("/api/messages/msg/\(messageID)/open", method: "POST") }
      }
    }
  }

  func ignore(_ nick: String) {
    ignored.insert(nick.lowercased())
    UserDefaults.standard.set(Array(ignored).sorted(), forKey: "ignoredUsers")
  }

  func replaceIgnored(_ nicks: [String]) {
    let replacement = Set(nicks.map { $0.lowercased() })
    guard ignored != replacement else { return }
    ignored = replacement
    UserDefaults.standard.set(ignored.sorted(), forKey: "ignoredUsers")
  }
  func replaceHighlighted(_ nicks: [String]) {
    let replacement = Set(nicks.map { $0.lowercased() })
    guard highlighted != replacement else { return }
    highlighted = replacement
    UserDefaults.standard.set(highlighted.sorted(), forKey: "highlightedUsers")
  }

  func clearIgnored() {
    ignored.removeAll()
    UserDefaults.standard.removeObject(forKey: "ignoredUsers")
  }

  private func consume(_ event: ChatEvent) {
    switch event {
    case .identity(let user):
      if conversationOwner != user?.id { resetPrivateMessages(); conversationOwner = user?.id }
      account = user; identity = user?.nick
      if let user, DestinyAccount.hasSession { UserDefaults.standard.set(user.nick, forKey: "destinyLogin") }
      if user != nil, DestinyAccount.hasSession, ChatPreferences.automaticSync {
        Task { [weak self] in
          guard let self else { return }
          do { try await ChatPreferences.load(into: self) }
          catch is CancellationError {} catch { if identity == user?.nick { self.error = "Website settings: " + error.localizedDescription } }
        }
      }
      if hasSession, user == nil { error = "Destiny.gg did not accept your sign-in. Sign in again in Account settings." }
    case .updateUser(let user):
      if !user.nick.isEmpty { remember(user) }
      if let own = account,
        (own.userID != nil && own.userID == user.userID) || own.id == user.id {
        account = user; identity = user.nick
      }
    case .message(let message):
      if let id = message.userID, id > 0 { remember(message.user) }
      if !replayingHistory, !ignored.contains(message.nick.lowercased()) {
        if message.whisper && UserDefaults.standard.bool(forKey: "notifyChatWhispers") {
          ChatPreferences.notify(message)
        } else if !message.whisper, let identity, message.nick.caseInsensitiveCompare(identity) != .orderedSame,
          (Self.mentions(identity, in: message.text) || ChatPreferences.highlighted(message.text)),
          UserDefaults.standard.bool(forKey: "notifyChatMentions") { ChatPreferences.notify(message) }
      }
      if message.whisper {
        guard !ignored.contains(message.nick.lowercased()) else { return }
        addWhisper(message, conversation: message.nick, incoming: true)
        enqueue([message])
      } else {
        enqueue([message])
        if message.heading != nil && message.kind != "SYSTEM" {
          if !paidEvents.contains(where: { $0.id == message.id }), message.eventExpiry.map({ $0 > Date() }) == true {
            paidEvents.append(message); paidEvents = Array(paidEvents.suffix(50)); scheduleEvents()
          }
          if let key = message.spotlightKey { spotlights[key] = message }
        }
      }
    case .history(let history):
      let previous = replayingHistory
      replayingHistory = true
      for event in history { consume(event) }
      replayingHistory = previous
    case .paidEvents(let events): paidEvents = Array(events.filter { $0.eventExpiry.map { $0 > Date() } == true }.suffix(50)); scheduleEvents()
    case .spotlights(let events): spotlights = Dictionary(events.compactMap { event in event.spotlightKey.map { ($0, event) } }, uniquingKeysWith: { _, new in new })
    case .unspotlight(let key): spotlights.removeValue(forKey: key)
    case .removeEvent(let id): paidEvents.removeAll { $0.id == id }; scheduleEvents()
    case .error(let failure):
      votePending = false; voteTimeout?.cancel()
      error = failure.message
      if let seconds = failure.muteSeconds, seconds.isFinite, seconds > 0 {
        setMuteExpiry(Date().addingTimeInterval(min(seconds, 604800)))
      }
      if failure.code == "banned" { banned = true }
      if ["banned", "toomanyconnections"].contains(failure.code) { retryAllowed = false }
      if !pendingWhispers.isEmpty { pendingWhispers.removeFirst() }
    case .pinned(let message): pinned = message
    case .moderation(let command, let actor, let target, let duration, let timestamp):
      if ["BAN", "MUTE", "DEATH"].contains(command) {
        for index in pending.indices where pending[index].nick.caseInsensitiveCompare(target) == .orderedSame
          && pending[index].timestamp <= timestamp { pending[index].removed = true }
        buffer.moderate(nick: target, timestamp: timestamp)
      }
      messages = buffer.messages
      if identity?.caseInsensitiveCompare(target) == .orderedSame {
        if command == "BAN" { banned = true }
        if ["UNBAN", "UNMUTE"].contains(command) { setMuteExpiry(nil); if command == "UNBAN" { banned = false } }
        if ["MUTE", "DEATH"].contains(command), timestamp.isFinite, duration.isFinite, duration > 0 {
          let until = Date(timeIntervalSince1970: timestamp / 1000 + min(duration, 604800))
          if until > Date() { setMuteExpiry(until) }
        }
      }
      system("\(target): \(command.lowercased()) by \(actor)")
    case .names(let list):
      userRevision += 1
      users = Dictionary(list.filter { !$0.nick.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    case .presence(let joined, let removed):
      for user in joined where !user.nick.isEmpty { remember(user) }
      for nick in removed { users.removeValue(forKey: nick.lowercased()) }
    case .subOnly(let tier): subOnly = tier
    case .poll(let poll):
      self.poll = poll; pollVisible = true
      votePending = false; voteTimeout?.cancel()
      pollExpiry?.cancel()
      pollExpiry = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(max(0, poll.ends.timeIntervalSinceNow))) } catch { return }
        if self?.poll?.id == poll.id { self?.poll?.ended = true }
      }
    case .pollStop: poll?.ended = true; pollExpiry?.cancel(); votePending = false; voteTimeout?.cancel()
    case .vote(let option, let quantity):
      if let count = poll?.options.count, (1...count).contains(option) { poll?.totals[option - 1] += quantity }
    case .voteCounted(let option): poll?.myVote = option; poll?.canVote = false; votePending = false; voteTimeout?.cancel()
    case .whisperSent:
      if !pendingWhispers.isEmpty {
        let sent = pendingWhispers.removeFirst()
        let message = ChatMessage(payload: ["nick": identity ?? "Me", "data": sent.text], whisper: true, kind: "PRIVMSG", recipient: sent.nick)
        addWhisper(message, conversation: sent.nick, incoming: false)
        enqueue([message])
      }
    case .reloadAssets(let key):
      if let key, key != assetCacheKey {
        assetCacheKey = key
        assetRevision += 1
      }
    case .reload: Task { await restart() }
    case .ping, .other: break
    }
  }

  private func setMuteExpiry(_ until: Date?) {
    muteExpiry?.cancel()
    mutedUntil = until
    guard let until else { return }
    muteExpiry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow))) } catch { return }
      if self?.mutedUntil == until { self?.mutedUntil = nil }
    }
  }

  private func scheduleEvents() {
    eventExpiry?.cancel()
    paidEvents.removeAll { $0.eventExpiry.map { $0 <= Date() } == true }
    guard let next = paidEvents.compactMap(\.eventExpiry).min() else { return }
    eventExpiry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) } catch { return }
      self?.scheduleEvents()
    }
  }

  private func enqueue(_ messages: [ChatMessage]) {
    pending.append(contentsOf: messages)
    if pending.count >= 500 {
      flush()
    } else if !pending.isEmpty, publisher == nil {
      // Coalesce busy chat without waking the app while no messages arrive.
      publisher = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        self?.flush()
      }
    }
  }

  private func flush() {
    publisher?.cancel()
    publisher = nil
    guard !pending.isEmpty else { return }
    buffer.append(pending)
    pending.removeAll(keepingCapacity: true)
    messages = buffer.messages
  }
}
