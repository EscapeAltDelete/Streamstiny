import Foundation

struct StreamSource: Identifiable, Equatable, Codable, Sendable {
  enum Provider: String, CaseIterable, Codable, Sendable {
    case youtube = "YouTube"
    case twitch = "Twitch"
    case kick = "Kick"
    case rumble = "Rumble"
    case angelthump = "AngelThump"
    case vimeo = "Vimeo"
    case facebook = "Facebook"
    case direct = "Direct video"
    var platform: String {
      switch self {
      case .direct: return "direct"
      default: return rawValue.lowercased()
      }
    }
    static func platform(_ name: String) -> Self? {
      platforms[name.lowercased()]
    }
    private static let platforms: [String: Self] = {
      var values = Dictionary(uniqueKeysWithValues: allCases.map { ($0.platform, $0) })
      values.merge([
        "twitch.tv": .twitch, "kick.com": .kick, "angelthump.com": .angelthump,
        "youtube.com": .youtube, "youtu.be": .youtube, "vimeo.com": .vimeo,
        "rumble.com": .rumble, "facebook.com": .facebook,
      ]) { _, alias in alias }
      return values
    }()
  }
  let provider: Provider
  let key: String
  var id: String {
    "\(provider.platform):\(provider == .youtube || provider == .direct ? key : key.lowercased())"
  }
  var title: String {
    "\(provider.rawValue) · \(provider == .direct ? URL(string: key)?.host ?? "Stream" : key)"
  }
  func matches(_ other: StreamSource?) -> Bool {
    guard let other, provider == other.provider else { return false }
    if provider == .twitch || provider == .kick { return key.caseInsensitiveCompare(other.key) == .orderedSame }
    return key == other.key
  }

  static let initial = StreamSource(provider: .youtube, key: "UC554eY5jNUfDq3yDOJYirOQ")
  var isYouTubeChannel: Bool {
    provider == .youtube && (key.hasPrefix("@") || (key.hasPrefix("UC") && key.count == 24))
  }

  var pageURL: URL? {
    switch provider {
    case .youtube:
      if isYouTubeChannel {
        let base = URL(string: "https://www.youtube.com")!
        return key.hasPrefix("@")
          ? base.appendingPathComponent(key).appendingPathComponent("live")
          : base.appendingPathComponent("channel").appendingPathComponent(key)
            .appendingPathComponent("live")
      }
      return URL(string: "https://www.youtube.com/watch?v=\(key)")
    case .twitch: return URL(string: "https://www.twitch.tv/\(key)")
    case .kick: return URL(string: "https://kick.com/\(key)")
    case .rumble: return URL(string: "https://rumble.com/embed/\(key)/")
    case .angelthump: return URL(string: "https://angelthump.com/\(key)")
    case .vimeo: return URL(string: "https://vimeo.com/\(key)")
    case .facebook: return URL(string: "https://www.facebook.com/\(key)")
    case .direct: return URL(string: key)
    }
  }

  static func parse(_ input: String, provider: Provider? = nil) throws -> StreamSource {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let input = trimmed.hasPrefix("#") ? "https://www.destiny.gg/bigscreen" + trimmed : trimmed
    var chosen = provider
    var key = input
    if let url = URL(string: input), url.scheme != nil {
      guard url.scheme == "https", url.user == nil, url.password == nil else {
        throw SourceError.invalid
      }
      let host = url.host?.lowercased() ?? ""
      let path = url.path.split(separator: "/").map(String.init)
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      if ["www.destiny.gg", "destiny.gg"].contains(host), let fragment = url.fragment {
        let parts = fragment.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let platform = Provider.platform(parts[0]) else {
          throw SourceError.invalid
        }
        key = parts[1].components(separatedBy: "?")[0].trimmingCharacters(
          in: CharacterSet(charactersIn: "/"))
        chosen = platform
      } else if chosen == .direct
        || url.pathExtension.lowercased() == "m3u8"
      {
        chosen = .direct
        key = input
      } else {
        switch host {
        case "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be":
          chosen = .youtube
          if host == "youtu.be" {
            key = path.first ?? ""
          } else if let video = query.first(where: { $0.name == "v" })?.value {
            key = video
          } else if path.count >= 2, ["channel", "live", "embed"].contains(path[0]) {
            key = path[1]
          } else if let handle = path.first, handle.hasPrefix("@"),
            path.count == 1 || (path.count == 2 && path[1] == "live")
          {
            key = handle
          } else {
            throw SourceError.invalid
          }
        case "twitch.tv", "www.twitch.tv", "player.twitch.tv":
          chosen = .twitch
          key = query.first(where: { $0.name == "channel" })?.value ?? path.first ?? ""
        case "kick.com", "www.kick.com", "player.kick.com":
          chosen = .kick
          key = path.first ?? ""
        case "angelthump.com", "www.angelthump.com", "player.angelthump.com":
          chosen = .angelthump
          key = query.first(where: { $0.name == "channel" })?.value ?? path.first ?? ""
        case "rumble.com", "www.rumble.com":
          guard path.count >= 2, path[0] == "embed" else { throw SourceError.rumbleEmbed }
          chosen = .rumble
          key = path[1]
        case "vimeo.com", "www.vimeo.com", "player.vimeo.com":
          chosen = .vimeo
          key = path.last ?? ""
        case "facebook.com", "www.facebook.com", "m.facebook.com":
          chosen = .facebook
          key = path.joined(separator: "/")
        default: throw SourceError.invalid
        }
        if let provider, provider != chosen { throw SourceError.invalid }
      }
    }
    guard let chosen else { throw SourceError.invalid }
    if chosen == .direct {
      guard let url = URL(string: key), url.scheme == "https", url.host != nil,
        url.pathExtension.lowercased() == "m3u8"
      else { throw SourceError.invalid }
    } else {
      let segments = key.split(separator: "/", omittingEmptySubsequences: false)
      let expected = chosen == .facebook ? segments.count : 1
      let youtubeHandle = chosen == .youtube && key.hasPrefix("@")
      guard !key.isEmpty, key.count <= 150, segments.count == expected,
        segments.allSatisfy({
          !$0.isEmpty
            && (youtubeHandle ? $0.dropFirst() : $0[...]).allSatisfy {
              ($0.isASCII || youtubeHandle)
                && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
                  || (youtubeHandle && $0 == "."))
            }
        })
      else { throw SourceError.invalid }
      if youtubeHandle, key.count < 2 { throw SourceError.invalid }
      if chosen == .vimeo { guard key.allSatisfy(\.isNumber) else { throw SourceError.invalid } }
    }
    return StreamSource(provider: chosen, key: key)
  }
}

enum SourceError: LocalizedError {
  case invalid, rumbleEmbed
  var errorDescription: String? {
    switch self {
    case .invalid: return "Paste an HTTPS stream URL or a Destiny.gg bigscreen link."
    case .rumbleEmbed: return "Use the Rumble embed URL from its Embed button."
    }
  }
}
