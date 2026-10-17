import Foundation

struct PlaybackMedia: Sendable {
  let url: URL
  let variants: [HLSVariant]?
  let headers: [String: String]
  init(
    _ url: URL, variants: [HLSVariant]? = nil,
    headers: [String: String] = [:]
  ) {
    self.url = url
    self.variants = variants
    self.headers = headers
  }
}

enum PlaybackFailure: LocalizedError {
  case offline, unavailable, restricted
  case http(Int)
  var errorDescription: String? {
    switch self {
    case .offline: return "This channel is offline. Choose another stream from the player menu."
    case .unavailable:
      return "This provider has not supplied playable native video for this source."
    case .restricted:
      return "This video requires provider authorization or an unsupported protected player."
    case .http(let status):
      return "The playback service returned HTTP \(status). Try again shortly."
    }
  }
}

// Only media returned by public viewer interfaces is used. No signature deciphering,
// DRM removal, credential sharing, or ad-manifest rewriting.
actor PlaybackResolver {
  static let userAgent =
    "Streamstiny/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
  private let session: URLSession
  private lazy var youtube = YouTubeResolver(session: session)
  private lazy var twitch = TwitchResolver(session: session)
  init(configuration config: URLSessionConfiguration = .ephemeral) {
    config.timeoutIntervalForRequest = 20
    config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
    config.httpMaximumConnectionsPerHost = 4
    session = URLSession(configuration: config)
  }

  deinit { session.invalidateAndCancel() }

  func twitchAlternative(_ source: StreamSource, playerType: String) async throws -> PlaybackMedia {
    try await twitch.alternative(source, playerType: playerType)
  }

  func variants(at url: URL) async throws -> [HLSVariant] {
    guard url.pathExtension.lowercased() == "m3u8" else { return [] }
    let (data, response) = try await session.data(from: url)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      data.count <= 2 * 1024 * 1024
    else { throw PlaybackFailure.unavailable }
    let text = String(decoding: data, as: UTF8.self)
    guard text.hasPrefix("#EXTM3U") else { throw PlaybackFailure.unavailable }
    return HLSPlaylist.variants(text, base: response.url ?? url)
  }

  func verifiedEdge(_ edge: AngelEdge, variant: HLSVariant) async throws -> URL {
    guard !variant.externalMedia, let url = edge.replacingHost(in: variant.url) else {
      throw PlaybackFailure.unavailable
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.url?.host == url.host,
      data.count <= 2 * 1024 * 1024
    else { throw PlaybackFailure.unavailable }
    let text = String(decoding: data, as: UTF8.self)
    guard text.hasPrefix("#EXTM3U"),
      let line = text.components(separatedBy: .newlines).last(where: {
        !$0.isEmpty && !$0.hasPrefix("#")
      }),
      let segment = URL(string: line, relativeTo: response.url ?? url)?.absoluteURL,
      segment.scheme == "https", segment.host == url.host
    else {
      throw PlaybackFailure.unavailable
    }
    var probe = URLRequest(url: segment)
    probe.timeoutInterval = 5
    probe.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
    let (bytes, result) = try await session.data(for: probe)
    guard let result = result as? HTTPURLResponse, [200, 206].contains(result.statusCode),
      result.url?.host == url.host,
      !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024
    else { throw PlaybackFailure.unavailable }
    return url
  }

  func resolve(_ source: StreamSource) async throws -> PlaybackMedia {
    switch source.provider {
    case .direct:
      guard let url = source.pageURL else { throw SourceError.invalid }
      return PlaybackMedia(url)
    case .kick:
      let json = try await object("https://kick.com/api/v2/channels/\(source.key)")
      guard json["livestream"] is [String: Any] else { throw PlaybackFailure.offline }
      return try media(json["playback_url"] as? String)
    case .angelthump:
      let data = try await fetch("https://api.angelthump.com/v3/streams?username=\(source.key)")
      let streams = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
      guard let stream = streams.first, stream["type"] as? String == "live" else {
        throw PlaybackFailure.offline
      }
      let user = stream["user"] as? [String: Any] ?? [:]
      guard user["password_protect"] as? Bool != true, user["banned"] as? Bool != true else {
        throw PlaybackFailure.restricted
      }
      // Public player identifier, not an account credential. Patreon access stays false.
      let grant = try await object(
        "https://vigor.angelthump.com/\(source.key)/token",
        body: Data(#"{"patreon":false}"#.utf8), headers: ["Identifier": "SwnpX0RnA99YdRj0SPqs"])
      guard let token = grant["token"] as? String else { throw PlaybackFailure.restricted }
      var url = URLComponents(string: "https://vigor.angelthump.com/hls/\(source.key).m3u8")!
      url.queryItems = [URLQueryItem(name: "token", value: token)]
      guard let address = url.url else { throw SourceError.invalid }
      return PlaybackMedia(address)
    case .rumble:
      let json = try await object(
        "https://rumble.com/embedJS/u3/?request=video&ver=2&v=\(source.key)")
      return try media(Self.rumbleURL(json))
    case .vimeo:
      let json = try await object("https://player.vimeo.com/video/\(source.key)/config")
      let request = json["request"] as? [String: Any] ?? [:]
      let files = request["files"] as? [String: Any] ?? [:]
      if let hls = files["hls"] as? [String: Any],
        let cdns = hls["cdns"] as? [String: [String: Any]]
      {
        let name = hls["default_cdn"] as? String ?? ""
        if let url = cdns[name]?["url"] as? String { return try media(url) }
      }
      throw PlaybackFailure.unavailable
    case .youtube:
      return try await youtube.resolve(source)
    case .facebook:
      guard let page = source.pageURL else { throw SourceError.invalid }
      let html = String(decoding: try await fetch(page.absoluteString), as: UTF8.self)
      return try media(Self.jsonString(in: html, named: "playable_url"))
    case .twitch:
      return try await twitch.resolve(source)
    }
  }

  private func media(_ text: String?) throws -> PlaybackMedia {
    guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil
    else { throw PlaybackFailure.unavailable }
    return PlaybackMedia(url)
  }
  private func object(_ address: String, body: Data? = nil, headers: [String: String] = [:])
    async throws -> [String: Any]
  {
    let data = try await fetch(address, body: body, headers: headers)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PlaybackFailure.unavailable
    }
    return json
  }
  private func fetch(_ address: String, body: Data? = nil, headers: [String: String] = [:])
    async throws -> Data
  {
    guard let url = URL(string: address) else { throw SourceError.invalid }
    var request = URLRequest(url: url)
    request.httpBody = body
    if body != nil {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (data, response) = try await session.data(for: request)
    guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
      throw PlaybackFailure.http((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    guard data.count <= 8 * 1024 * 1024 else { throw PlaybackFailure.unavailable }
    return data
  }

  static func rumbleURL(_ json: [String: Any]) -> String? {
    // Rumble's viewer configuration has used both grouped streams and ua/u maps.
    func urls(_ value: Any) -> [String] {
      if let string = value as? String { return [string] }
      if let dictionary = value as? [String: Any] {
        return dictionary.keys.sorted().flatMap { urls(dictionary[$0]!) }
      }
      if let array = value as? [Any] { return array.flatMap(urls) }
      return []
    }
    return (urls(json["u"] ?? [:]) + urls(json["ua"] ?? [:]))
      .first { URL(string: $0)?.pathExtension.lowercased() == "m3u8" }
  }

  static func jsonObject(in html: String, following marker: String) -> [String: Any]? {
    guard let range = html.range(of: marker),
      let start = html[range.upperBound...].firstIndex(of: "{")
    else { return nil }
    return jsonObject(in: html, from: start)
  }
  static func jsonObject(in html: String, from start: String.Index) -> [String: Any]? {
    guard let data = jsonData(in: html, from: start) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func jsonData(in html: String, from start: String.Index) -> Data? {
    var depth = 0
    var quoted = false
    var escaped = false
    for index in html[start...].indices {
      let char = html[index]
      if quoted {
        if escaped {
          escaped = false
        } else if char == "\\" {
          escaped = true
        } else if char == "\"" {
          quoted = false
        }
      } else if char == "\"" {
        quoted = true
      } else if char == "{" {
        depth += 1
      } else if char == "}" {
        depth -= 1
        if depth == 0 {
          return Data(html[start...index].utf8)
        }
      }
    }
    return nil
  }
  static func jsonString(in html: String, named name: String) -> String? {
    guard
      let regex = try? NSRegularExpression(
        pattern: "\"" + NSRegularExpression.escapedPattern(for: name)
          + "\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")"),
      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
      let range = Range(match.range(at: 1), in: html)
    else { return nil }
    return try? JSONSerialization.jsonObject(
      with: Data(html[range].utf8), options: .fragmentsAllowed) as? String
  }
}
