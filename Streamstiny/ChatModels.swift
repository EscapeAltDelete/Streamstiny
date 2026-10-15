import Foundation

struct ChatUser: Identifiable, Equatable, Sendable {
  let userID: Int?
  let nick: String
  let features: [String]
  let roles: [String]
  let bio: String?
  let created: String?
  let age: String?
  let gender: String?
  let watching: StreamSource?
  var id: String { nick.lowercased() }
  var moderator: Bool { roles.contains("ADMIN") || roles.contains("MODERATOR") }
  var canRemoveEvents: Bool { moderator || roles.contains("EVENTS") }
  var canPoll: Bool { moderator || roles.contains("POLLS") }
  var privileged: Bool { moderator || roles.contains("PROTECTED") }
  var tier: Int {
    for (index, flair) in ["flair13", "flair1", "flair3", "flair8", "flair42"].enumerated().reversed() {
      if features.contains(flair) { return index + 1 }
    }
    return 0
  }
  init(_ payload: [String: Any]) {
    userID = payload["id"] as? Int ?? payload["userId"] as? Int
    nick = payload["nick"] as? String ?? payload["username"] as? String ?? ""
    features = payload["features"] as? [String] ?? []
    roles = payload["roles"] as? [String] ?? []
    bio = payload["bio"] as? String
    created = payload["createdDate"] as? String
    age = payload["age"] as? String
    gender = payload["gender"] as? String
    if let embed = payload["watching"] as? [String: Any], let platform = embed["platform"] as? String,
      let provider = StreamSource.Provider.platform(platform), let key = embed["id"] as? String {
      watching = try? StreamSource.parse(key, provider: provider)
    } else { watching = nil }
  }
}

struct ChatPoll: Equatable, Sendable {
  let id: String
  let question: String
  let options: [String]
  let nick: String
  let weighted: Bool
  let ends: Date
  var totals: [Int]
  var canVote: Bool
  var myVote: Int
  var ended = false
  var total: Int { totals.reduce(0, +) }
  init?(_ payload: [String: Any], received: Date = Date()) {
    guard let question = payload["question"] as? String,
      let options = payload["options"] as? [String], (2...100).contains(options.count),
      let start = payload["start"] as? Double, start.isFinite,
      let duration = payload["time"] as? Double, duration.isFinite, duration >= 0, duration <= 600_000
    else { return nil }
    self.question = question
    self.options = options
    nick = payload["nick"] as? String ?? ""
    weighted = payload["weighted"] as? Bool ?? false
    id = "\(start):\(nick):\(question)"
    let now = payload["now"] as? Double ?? received.timeIntervalSince1970 * 1000
    guard now.isFinite else { return nil }
    ends = received.addingTimeInterval((start + duration - now) / 1000)
    let incoming = payload["totals"] as? [Int] ?? []
    totals = options.indices.map { $0 < incoming.count ? max(0, incoming[$0]) : 0 }
    myVote = payload["myvote"] as? Int ?? 0
    canVote = (payload["canvote"] as? Bool ?? false) && myVote == 0
  }
}

struct ChatServerError: Sendable {
  let code: String
  let muteSeconds: Double?
  let message: String
  init(_ value: Any) {
    let payload = value as? [String: Any] ?? [:]
    code = payload["description"] as? String ?? value as? String ?? "Chat request rejected"
    muteSeconds = payload["muteTimeLeft"] as? Double
    switch code {
    case "needlogin", "notloggedin": message = "Sign in to Destiny.gg in Account settings to send messages."
    case "invalidtoken": message = "Your Destiny.gg session was rejected. Sign in again."
    case "muted": message = "You are temporarily muted."
    case "banned": message = "You are banned from chat. Check your Destiny.gg profile."
    case "submode": message = "Chat is subscriber-only (Tier \(payload["tier"] as? Int ?? 1)+)."
    case "duplicate": message = "You already sent that message."
    case "throttled", "ratelimit": message = "You are sending messages too quickly. Wait and try again."
    case "nopermission": message = "Your account does not have permission for that action."
    case "notfound": message = "That user could not be found."
    case "bannedphrase": message = "Your message contains a blocked phrase: \(payload["filtered"] as? String ?? "")."
    case "toomanyconnections": message = "Too many chat connections. Close another session and try again."
    default: message = code
    }
  }
}
