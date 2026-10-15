import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
  let id: String
  let user: ChatUser
  var nick: String { user.nick.isEmpty ? "System" : user.nick }
  let text: String
  let timestamp: Double
  var features: [String] { user.features }
  var roles: [String] { user.roles }
  let whisper: Bool
  let kind: String
  let heading: String?
  let board: [[Int]]?
  struct Contributor: Equatable, Sendable { let name: String; let amount: Int }
  let contributors: [Contributor]
  let audio: URL?
  let messageID: Int?
  let recipient: String?
  var userID: Int? { user.userID }
  let eventExpiry: Date?
  let spotlightKey: String?
  var comboNicks: [String] = []
  var removed = false

  init(payload: [String: Any], whisper: Bool = false, kind: String = "MSG", recipient: String? = nil) {
    let author = payload["user"] as? [String: Any]
      ?? (payload["user"] as? String).map { ["nick": $0] } ?? payload
    let user = ChatUser(author)
    self.user = user
    let nick = user.nick.isEmpty ? "System" : user.nick
    text = payload["data"] as? String ?? ""
    timestamp = payload["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000
    self.whisper = whisper
    self.kind = kind
    self.recipient = recipient
    spotlightKey = payload["key"] as? String
    if let expiry = payload["expirationTimestamp"] as? Double, expiry.isFinite {
      eventExpiry = Date(timeIntervalSince1970: expiry / 1000)
    } else { eventExpiry = nil }
    messageID = payload["messageid"] as? Int
    id = payload["uuid"] as? String ?? messageID.map { "whisper:\($0)" }
      ?? "\(kind):\(timestamp):\(nick):\(text):\(recipient ?? "")"
    let matrix = payload["characters"] as? [[Int]]
    board = matrix?.count == 6 && matrix?.allSatisfy({ $0.count == 22 }) == true ? matrix : nil
    contributors = Array((payload["contributors"] as? [[String: Any]] ?? []).prefix(20)).compactMap { entry in
      guard let name = entry["name"] as? String, let amount = entry["amountCents"] as? Int else { return nil }
      return Contributor(name: name, amount: amount)
    }
    let tier = payload["tierLabel"] as? String ?? "Tier \(payload["tier"] as? Int ?? 1)"
    switch kind {
    case "SUBSCRIPTION":
      let streak = payload["streak"] as? Int ?? 0
      heading = "\(nick) subscribed · \(tier)" + (streak > 0 ? " · \(streak) months" : "")
    case "GIFTSUB":
      let target = (payload["recipient"] as? [String: Any])?["nick"] as? String ?? "a user"
      heading = "\(nick) gifted \(target) a \(tier) subscription"
    case "MASSGIFT": heading = "\(nick) gifted \(payload["quantity"] as? Int ?? 0) \(tier) subscriptions"
    case "DONATION": heading = "\(nick) donated $" + String(format: "%.2f", (payload["amount"] as? Double ?? 0) / 100)
    case "BROADCAST": heading = user.nick.isEmpty || user.nick == "System" ? "Announcement" : "Announcement · \(nick)"
    case "XPOST": heading = "Cross-post · \(nick)"
    case "SPOTLIGHT": heading = "Spotlight · \(nick)"
    case "VESTABOARD_LEAD", "VESTABOARD_HOURLY", "VESTABOARD_RESET":
      let submitter = payload["submitter"] as? String ?? ""
      let amount = String(format: "%.2f", (payload["total"] as? Double ?? 0) / 100)
      heading = submitter.isEmpty ? "Vestaboard auction" : "Vestaboard · \(submitter) · $\(amount)"
    case "SYSTEM": heading = "Chat"
    default: heading = nil
    }
    audio = (payload["audio"] as? String).flatMap(URL.init(string:)).flatMap {
      $0.scheme == "https" && $0.host != nil ? $0 : nil
    }
  }
}

enum ChatEvent: Sendable {
  case identity(ChatUser?)
  case updateUser(ChatUser)
  case message(ChatMessage)
  case history([ChatEvent])
  case paidEvents([ChatMessage])
  case spotlights([ChatMessage])
  case unspotlight(String)
  case removeEvent(String)
  case error(ChatServerError)
  case ping(String)
  case moderation(command: String, actor: String, target: String, duration: Double, timestamp: Double)
  case pinned(ChatMessage?)
  case names([ChatUser])
  case presence(joined: [ChatUser], removed: [String])
  case subOnly(Int)
  case poll(ChatPoll)
  case pollStop
  case vote(option: Int, quantity: Int)
  case voteCounted(Int)
  case whisperSent
  case reloadAssets
  case reload
  case other
}

enum ChatProtocol {
  static func decode(_ frame: String, depth: Int = 0) throws -> ChatEvent {
    guard depth < 4 else { return .other }
    guard let split = frame.firstIndex(of: " ") else { return .other }
    let command = String(frame[..<split])
    let body = String(frame[frame.index(after: split)...])
    if command == "PING" { return .ping(body) }
    if command == "RELOAD" { return .reload }
    if command == "REFRESHCHATASSETS" { return .reloadAssets }
    let value = try JSONSerialization.jsonObject(with: Data(body.utf8), options: .fragmentsAllowed)
    let payload = value as? [String: Any] ?? [:]
    switch command {
    case "ME":
      let user = ChatUser(payload)
      return .identity(user.nick.isEmpty ? nil : user)
    case "UPDATEUSER": return .updateUser(ChatUser(payload))
    case "MSG", "PRIVMSG", "BROADCAST", "SUBSCRIPTION", "GIFTSUB", "MASSGIFT", "DONATION",
      "XPOST", "SPOTLIGHT", "VESTABOARD_LEAD", "VESTABOARD_HOURLY", "VESTABOARD_RESET":
      return .message(ChatMessage(payload: payload, whisper: command == "PRIVMSG", kind: command))
    case "HISTORY":
      let frames = value as? [String] ?? []
      return .history(
        frames.compactMap { try? decode($0, depth: depth + 1) })
    case "PAIDEVENTS":
      return .paidEvents((value as? [String] ?? []).compactMap {
        if case .message(let message) = try? decode($0, depth: depth + 1) { return message }
        return nil
      })
    case "SPOTLIGHTS": return .spotlights((value as? [[String: Any]] ?? []).map { ChatMessage(payload: $0, kind: "SPOTLIGHT") })
    case "UNSPOTLIGHT": return .unspotlight(payload["key"] as? String ?? "")
    case "REMOVEEVENT": return .removeEvent(payload["data"] as? String ?? payload["uuid"] as? String ?? "")
    case "ERR": return .error(ChatServerError(value))
    case "BAN", "MUTE", "UNBAN", "UNMUTE", "DEATH":
      return .moderation(command: command, actor: payload["nick"] as? String ?? "System",
        target: payload[command == "DEATH" ? "nick" : "data"] as? String ?? "",
        duration: payload["duration"] as? Double ?? 0,
        timestamp: payload["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000)
    case "PIN":
      return .pinned(
        (payload["data"] as? String ?? "").isEmpty ? nil : ChatMessage(payload: payload, kind: "PIN"))
    case "NAMES": return .names((payload["users"] as? [[String: Any]] ?? []).map(ChatUser.init))
    case "JOIN": return .presence(joined: [ChatUser(payload)], removed: [])
    case "QUIT": return .presence(joined: [], removed: [payload["nick"] as? String ?? ""])
    case "USERSDELTA": return .presence(joined: (payload["users"] as? [[String: Any]] ?? []).map(ChatUser.init),
      removed: (payload["removed"] as? [[String: Any]] ?? []).compactMap { $0["nick"] as? String })
    case "SUBONLY": return .subOnly(payload["data"] as? String == "on" ? max(1, payload["tier"] as? Int ?? 1) : 0)
    case "POLLSTART": return ChatPoll(payload).map(ChatEvent.poll) ?? .other
    case "POLLSTOP": return .pollStop
    case "VOTECAST": return .vote(option: number(payload["vote"]), quantity: max(0, number(payload["quantity"])))
    case "VOTECOUNTED": return .voteCounted(number(payload["vote"]))
    case "PRIVMSGSENT": return .whisperSent
    default: return .other
    }
  }

  private static func number(_ value: Any?) -> Int { value as? Int ?? (value as? String).flatMap(Int.init) ?? 0 }
  static func frame(_ command: String, _ payload: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
    return command + " " + String(decoding: data, as: UTF8.self)
  }

  static func encode(text: String, recipient: String? = nil) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 500 else { throw ChatInputError.invalidLength }
    var payload = ["data": trimmed]
    if let recipient, !recipient.isEmpty { payload["nick"] = recipient }
    let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
    return "\(recipient == nil ? "MSG" : "PRIVMSG") \(String(decoding: data, as: UTF8.self))"
  }
}

enum ChatInputError: LocalizedError {
  case invalidLength, disconnected, loginRequired, invalidCommand(String)
  var errorDescription: String? {
    switch self {
    case .invalidLength: return "Messages must contain 1–500 characters."
    case .disconnected: return "Chat is disconnected. Wait for it to reconnect."
    case .loginRequired: return "Sign in to Destiny.gg in Account settings to send messages."
    case .invalidCommand(let usage): return usage
    }
  }
}

struct MessageBuffer: Sendable {
  let capacity: Int
  private(set) var messages: [ChatMessage] = []
  private var ids: Set<String> = []

  init(capacity: Int = 1000) {
    self.capacity = max(1, capacity)
  }

  mutating func append(_ incoming: [ChatMessage]) {
    for message in incoming where ids.insert(message.id).inserted {
      messages.append(message)
    }
    if messages.count > capacity {
      let count = messages.count - capacity
      for message in messages.prefix(count) { ids.remove(message.id) }
      messages.removeFirst(count)
    }
  }

  mutating func clear() { messages.removeAll(); ids.removeAll() }
  mutating func moderate(nick: String, timestamp: Double) {
    for index in messages.indices where messages[index].nick.caseInsensitiveCompare(nick) == .orderedSame
      && messages[index].timestamp <= timestamp { messages[index].removed = true }
  }
  mutating func removeWhispers() {
    messages.removeAll { message in
      guard message.whisper else { return false }
      ids.remove(message.id); return true
    }
  }
}
