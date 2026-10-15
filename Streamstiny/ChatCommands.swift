import Foundation

extension ChatStore {
  @MainActor func command(_ raw: String) async throws -> Bool {
    let parts = raw.dropFirst().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard let name = parts.first?.lowercased() else { return false }
    let args = Array(parts.dropFirst())
    let text = args.joined(separator: " ")
    let target = args.first ?? ""
    switch name {
    case "help": system(Self.commandHelp)
    case "ignore":
      if args.isEmpty { system("Ignored: " + ignored.sorted().joined(separator: ", ")) }
      else { for nick in args { ignore(nick) } }
    case "unignore": for nick in args { unignore(nick) }
    case "unignoreall": clearIgnored()
    case "highlight", "unhighlight": for nick in args { highlight(nick, enabled: name == "highlight") }
    case "tag":
      guard args.count >= 2, Self.tagColorNames.contains(args[1].lowercased()) else { throw ChatInputError.invalidCommand("Usage: /tag nick color [note]") }
      tag(target, text: args.dropFirst(2).joined(separator: " "), color: args[1].lowercased())
    case "untag": for nick in args { tag(nick, text: nil) }
    case "untagall": for nick in Array(tags.keys) { tag(nick, text: nil) }
    case "clear": clearMessages()
    case "maxlines":
      guard let count = Int(target), (100...5000).contains(count) else {
        throw ChatInputError.invalidCommand("Usage: /maxlines 100–5000")
      }
      setMaximumMessages(count)
    case "timestampformat":
      guard !text.isEmpty, text.count <= 80 else { throw ChatInputError.invalidCommand("Usage: /timestampformat HH:mm") }
      UserDefaults.standard.set(text, forKey: "chatTimestampFormat")
    case "connect": await restart()
    case "embed", "e": requestedSource = try StreamSource.parse(target)
    case "postembed", "pe":
      let source = (try? StreamSource.parse(target)) ?? selectedSource
      guard let source, source.provider != .direct else {
        throw ChatInputError.invalidCommand("Select a stream or provide its URL.")
      }
      let note = (try? StreamSource.parse(target)) == nil ? text : args.dropFirst().joined(separator: " ")
      return await send("#\(source.provider.platform)/\(source.key) " + note)
    case "host", "unhost":
      guard account?.moderator == true || account?.roles.contains("HOST") == true else {
        throw ChatInputError.invalidCommand("Your account cannot host streams.")
      }
      var payload: [String: String] = [:]
      if name == "host" {
        var index = 0
        while index < args.count {
          if args[index] == "--display-name" || args[index] == "--title" {
            guard index + 1 < args.count else { throw ChatInputError.invalidCommand("A host option is missing its value.") }
            payload[args[index] == "--title" ? "title" : "displayName"] = args[index + 1]
            index += 2
          } else { payload["url"] = args[index]; index += 1 }
        }
        guard let address = payload["url"], let url = URL(string: address), url.scheme == "https", url.host != nil else {
          throw ChatInputError.invalidCommand("Usage: /host https://provider/stream [--title title] [--display-name name]")
        }
      }
      let data = try await DestinyAccount.request("/api/stream/" + name, method: "POST", body: try JSONSerialization.data(withJSONObject: payload))
      guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["success"] as? Bool == true else {
        throw ChatInputError.invalidCommand("Destiny.gg did not accept the hosting request.")
      }
    case "hint": system("Tap a pin or poll to expand it. Long press a message for user actions. /help lists commands.")
    case "open", "o":
      guard !target.isEmpty else { throw ChatInputError.invalidCommand("Usage: /open nick") }
      openConversation(target)
    case "exit": activeRecipient = nil
    case "message", "msg", "whisper", "w", "tell", "t", "notify":
      guard args.count >= 2 else { throw ChatInputError.invalidCommand("Usage: /w nick message") }
      return await send(args.dropFirst().joined(separator: " "), recipient: target)
    case "reply", "r":
      guard let last = lastWhisperRecipient else { throw ChatInputError.invalidCommand("No whisper to reply to.") }
      if text.isEmpty { openConversation(last) } else { return await send(text, recipient: last) }
    case "showpoll", "showvote": pollVisible = true
    case "poll", "vote", "v", "spoll", "svote":
      guard account?.canPoll == true else { throw ChatInputError.invalidCommand("Your account cannot start polls.") }
      guard poll == nil || poll?.ended == true else { throw ChatInputError.invalidCommand("A poll is already running.") }
      try await transmit("STARTPOLL", ChatPollInput.parse(text, weighted: ["spoll", "svote"].contains(name)))
    case "pollstop", "votestop", "vs":
      guard account?.canPoll == true else { throw ChatInputError.invalidCommand("Your account cannot stop polls.") }
      try await transmit("STOPPOLL", [:])
    case "pin", "motd", "unpin", "unmotd", "broadcast", "mute", "unmute", "ban", "ipban", "unban", "subonly",
      "addphrase", "addban", "addmute", "removephrase", "removeban", "removemute", "deletephrase", "deleteban", "deletemute", "dphrase", "dban", "dmute", "reloadusers":
      guard account?.moderator == true else { throw ChatInputError.invalidCommand("This action requires a moderator role.") }
      try await transmitModerator(name, args: args)
    case "stalk", "s", "mentions", "m":
      let isMentions = ["mentions", "m"].contains(name)
      let nick = Int(target) != nil || target.isEmpty ? identity ?? "" : target
      let limit = min(100, max(1, Int(args.last ?? "") ?? 10))
      guard !nick.isEmpty else { throw ChatInputError.loginRequired }
      let escaped = nick.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?#+"))) ?? ""
      let data = try await DestinyAccount.request("/api/chat/\(isMentions ? "mentions" : "stalk")?username=\(escaped)&limit=\(limit)")
      guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any], payload["success"] as? Bool == true else {
        throw ChatInputError.invalidCommand("Message history is unavailable for this account.")
      }
      let stalk = payload["data"] as? [String: Any] ?? [:]
      let rows = isMentions ? payload["data"] as? [[String: Any]] ?? [] : stalk["lines"] as? [[String: Any]] ?? []
      for row in rows {
        system("\(row["nick"] as? String ?? nick): \(row["text"] as? String ?? "")")
      }
      if rows.isEmpty { system("No matching messages.") }
    case "baninfo":
      let data = try await DestinyAccount.request("/api/chat/me/ban")
      let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
      if value as? String == "bannotfound" { system("You have no active bans.") }
      else if let payload = value as? [String: Any] {
        system(payload["reason"] as? String ?? payload["message"] as? String ?? "Check your Destiny.gg profile for your ban status.")
      }
    case "die", "suicide", "bitly": try await transmit("DIE", ["data": ""])
    default: throw ChatInputError.invalidCommand("Unknown command /\(name). Use /help for supported commands.")
    }
    return true
  }

  private func transmitModerator(_ name: String, args: [String]) async throws {
    let text = args.joined(separator: " ")
    let target = args.first ?? ""
    switch name {
    case "pin", "motd", "broadcast":
      guard !text.isEmpty else { throw ChatInputError.invalidCommand("Provide a message.") }
      try await transmit(name == "broadcast" ? "BROADCAST" : "PIN", ["data": text])
    case "unpin", "unmotd": try await transmit("PIN", ["data": ""])
    case "mute", "unmute", "unban":
      guard !target.isEmpty else { throw ChatInputError.invalidCommand("Provide a nickname.") }
      var payload: [String: Any] = ["data": target]
      if name == "mute", args.count > 1 { payload["duration"] = try ChatPollInput.duration(args[1]) * 1_000_000_000 }
      try await transmit(name.uppercased(), payload)
    case "ban", "ipban":
      guard args.count >= 3 else { throw ChatInputError.invalidCommand("Usage: /ban nick duration reason (duration can be permanent)") }
      var payload: [String: Any] = ["nick": target, "reason": args.dropFirst(2).joined(separator: " "), "banip": name == "ipban"]
      if args[1].lowercased().hasPrefix("perm") { payload["ispermanent"] = true }
      else { payload["duration"] = try ChatPollInput.duration(args[1]) * 1_000_000_000 }
      try await transmit("BAN", payload)
    case "subonly":
      guard let argument = args.first, ["on", "off", "1", "2", "3", "4", "5"].contains(argument) else {
        throw ChatInputError.invalidCommand("Usage: /subonly on|off|1–5")
      }
      try await transmit("SUBONLY", ["data": argument == "off" ? "off" : "on", "tier": Int(argument) ?? 1])
    case "reloadusers": try await transmit("RELOADUSERS", [:])
    default:
      guard !text.isEmpty else { throw ChatInputError.invalidCommand("Provide a phrase.") }
      try await transmit(["addphrase", "addban", "addmute"].contains(name) ? "ADDPHRASE" : "REMOVEPHRASE", ["data": text])
    }
  }

  static let commandHelp = """
  /me action · /w nick message · /r message · /open nick · /exit
  /ignore nick · /unignore nick · /unignoreall
  /highlight nick · /unhighlight nick · /tag nick color [note] · /untag nick
  /stalk nick [limit] · /mentions [nick] [limit] · /baninfo
  /showpoll · /poll question? option or option [30s] · /spoll · /pollstop
  /clear · /help
  /embed URL · /postembed [URL] [message] · /maxlines 100–5000 · /timestampformat HH:mm
  Moderators: /pin, /unpin, /broadcast, /mute, /unmute, /ban, /ipban, /unban, /subonly, /addphrase, /removephrase.
  """
}

enum ChatPollInput {
  static func duration(_ input: String) throws -> Double {
    let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800]
    let multiplier = input.last.flatMap { units[$0] } ?? 1
    let number = multiplier == 1 && input.last != "s" ? input : String(input.dropLast())
    guard let value = Double(number), value.isFinite, value > 0, value * multiplier <= 604800 else {
      throw ChatInputError.invalidCommand("Use a duration such as 30s, 5m, 1h, or 1d (up to 7 days).")
    }
    return value * multiplier
  }
  static func parse(_ input: String, weighted: Bool) throws -> [String: Any] {
    var text = input
    var seconds = 30.0
    if let last = text.split(separator: " ").last, last.last == "s" || last.last == "m" {
      if let value = try? duration(String(last)) {
        seconds = value
        text = String(text.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
      }
    }
    guard let split = text.firstIndex(of: "?") else {
      throw ChatInputError.invalidCommand("Usage: /poll question? option or option [30s]")
    }
    let question = String(text[...split])
    let rest = String(text[text.index(after: split)...]).trimmingCharacters(in: .whitespaces)
    let options = rest.isEmpty ? ["Yes", "No"] : rest.replacingOccurrences(of: "(?i)\\bor\\b", with: "\n", options: .regularExpression)
      .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    guard question.count <= 500, (2...100).contains(options.count), options.allSatisfy({ !$0.isEmpty && $0.count <= 500 }) else {
      throw ChatInputError.invalidCommand("Provide a question and at least two nonempty options separated by 'or'.")
    }
    return ["question": question, "options": options, "time": min(600, max(5, seconds)) * 1000, "weighted": weighted]
  }
}
