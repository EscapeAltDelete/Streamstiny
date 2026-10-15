import Foundation
import VideoToolbox

enum TwitchFailure: LocalizedError {
  case signIn, integrity
  var errorDescription: String? {
    switch self {
    case .signIn: return "Your Twitch session expired. Sign in again in Settings → Accounts."
    case .integrity: return "Twitch could not authorize playback. Sign out and sign back in under Settings → Accounts."
    }
  }
}

// Only resolution uses Twitch's web interface; video stays in the native player.
actor TwitchResolver {
  static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
  static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
  static let mediaHeaders = [
    "User-Agent": userAgent, "Referer": "https://player.twitch.tv/",
    "Origin": "https://player.twitch.tv",
  ]
  private let session: URLSession
  init(session: URLSession) { self.session = session }

  func resolve(_ source: StreamSource) async throws -> PlaybackMedia {
    var credentials = await TwitchAccount.shared.credentials()
    var renewedIntegrity = false
    var discardedSession = false
    for _ in 0..<3 {
      try Task.checkCancellation()
      do {
        return try await resolve(source, credentials: credentials)
      } catch TwitchFailure.signIn {
        guard credentials.token != nil, !discardedSession else { throw TwitchFailure.signIn }
        discardedSession = true
        await TwitchAccount.shared.invalidate(credentials.token)
        credentials = await TwitchAccount.shared.credentials()
      } catch TwitchFailure.integrity {
        // Browser work is only attempted when the normal native request requires it.
        guard !renewedIntegrity else { throw TwitchFailure.integrity }
        renewedIntegrity = true
        guard let proof = await TwitchAccount.shared.refreshIntegrity() else { throw TwitchFailure.integrity }
        credentials = proof
      }
    }
    throw PlaybackFailure.unavailable
  }

  func alternative(_ source: StreamSource, playerType: String) async throws -> PlaybackMedia {
    try await resolve(source, credentials: TwitchAccount.shared.credentials(), playerType: playerType)
  }

  private func resolve(_ source: StreamSource, credentials: TwitchCredentials, playerType: String = "site") async throws -> PlaybackMedia {
    try Task.checkCancellation()
    if source.provider == .twitchClip { return try await clip(source.key, credentials: credentials) }
    let live = source.provider == .twitch
    let key = live ? source.key.lowercased() : String(source.key.drop(while: { $0 == "v" }))
    let field = live ? "streamPlaybackAccessToken" : "videoPlaybackAccessToken"
    let argument = live ? "channelName: $key" : "id: $key"
    let type = live ? "String!" : "ID!"
    let query = "query NativePlayback($key: \(type), $playerType: String!, $platform: String!) { \(field)(\(argument), params: {platform: $platform, playerBackend: \"mediaplayer\", playerType: $playerType}) { value signature } }"
    let platform = playerType == "autoplay" ? "android" : "web"
    let data = try await gql(query, variables: ["key": key, "playerType": playerType, "platform": platform], credentials: credentials)
    guard let grant = data[field] as? [String: Any],
      let value = grant["value"] as? String, let signature = grant["signature"] as? String,
      !value.isEmpty, !signature.isEmpty
    else { throw live ? PlaybackFailure.offline : PlaybackFailure.unavailable }
    let token = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] ?? [:]
    if let authorization = token["authorization"] as? [String: Any],
      authorization["forbidden"] as? Bool == true { throw PlaybackFailure.restricted }
    var address = URLComponents(string: live
      ? "https://usher.ttvnw.net/api/v2/channel/hls/\(key).m3u8"
      : "https://usher.ttvnw.net/vod/\(key).m3u8")!
    let codecs = Self.supportedCodecs
    address.queryItems = [
      .init(name: "sig", value: signature), .init(name: "token", value: value),
      .init(name: "allow_source", value: "true"),
      .init(name: "multigroup_video", value: "true"),
      .init(name: "supported_codecs", value: codecs.joined(separator: ",")),
      .init(name: "reassignments_supported", value: "true"),
      .init(name: "platform", value: "web"), .init(name: "player_backend", value: "mediaplayer"),
      .init(name: "playlist_include_framerate", value: "true"),
      .init(name: "play_session_id", value: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
    ]
    guard let url = address.url else { throw PlaybackFailure.unavailable }
    var request = URLRequest(url: url)
    request.allHTTPHeaderFields = Self.mediaHeaders
    let (bytes, response) = try await session.data(for: request)
    try Task.checkCancellation()
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 404 { throw live ? PlaybackFailure.offline : PlaybackFailure.unavailable }
    if status == 401 || status == 403 { throw PlaybackFailure.restricted }
    guard status == 200 else { throw PlaybackFailure.http(status) }
    guard bytes.count <= 2 * 1024 * 1024 else { throw PlaybackFailure.unavailable }
    let text = String(decoding: bytes, as: UTF8.self)
    guard text.hasPrefix("#EXTM3U") else { throw PlaybackFailure.unavailable }
    let variants = HLSPlaylist.variants(text, base: response.url ?? url).filter { Self.supports($0.codecs) }
    guard !variants.isEmpty else { throw PlaybackFailure.unavailable }
    return PlaybackMedia(url, expires: Self.expiry(token),
      isLive: live, variants: variants, headers: Self.mediaHeaders)
  }

  private func clip(_ slug: String, credentials: TwitchCredentials) async throws -> PlaybackMedia {
    let query = "query NativeClip($slug: ID!) { clip(slug: $slug) { assets { aspectRatio videoQualities { bitrate codecs frameRate quality sourceURL } } playbackAccessToken(params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\"}) { value signature } } }"
    let data = try await gql(query, variables: ["slug": slug], credentials: credentials)
    guard let clip = data["clip"] as? [String: Any],
      let grant = clip["playbackAccessToken"] as? [String: Any],
      let token = grant["value"] as? String, let signature = grant["signature"] as? String,
      let assets = clip["assets"] as? [[String: Any]]
    else { throw PlaybackFailure.unavailable }
    // Prefer the horizontal asset to retain the player's landscape layout.
    let asset = assets.first { ($0["aspectRatio"] as? Double ?? 0) > 1 } ?? assets.first
    let qualities = asset?["videoQualities"] as? [[String: Any]] ?? []
    let variants = qualities.compactMap { item -> HLSVariant? in
      guard let address = item["sourceURL"] as? String,
        var url = URLComponents(string: address), url.scheme == "https", url.host != nil,
        url.user == nil, url.password == nil,
        let height = Int(item["quality"] as? String ?? ""), height > 0, height <= 16_384
      else { return nil }
      let codecs = item["codecs"] as? String ?? ""
      guard Self.supports(codecs) else { return nil }
      var items = url.queryItems ?? []
      items.removeAll { ["sig", "token"].contains($0.name) }
      items += [.init(name: "sig", value: signature), .init(name: "token", value: token)]
      url.queryItems = items
      guard let media = url.url else { return nil }
      let ratio = asset?["aspectRatio"] as? Double ?? 16.0 / 9.0
      let fps = item["frameRate"] as? Double ?? 0
      let bitrate = item["bitrate"] as? Double ?? 0
      guard ratio.isFinite, ratio > 0, ratio <= 10, fps.isFinite, fps >= 0, fps <= 240,
        bitrate.isFinite, bitrate >= 0 else { return nil }
      return HLSVariant(url: media, width: Int(Double(height) * ratio), height: height,
        bandwidth: bitrate, frameRate: fps, externalMedia: false, codecs: codecs)
    }.sorted { $0.height == $1.height ? $0.frameRate > $1.frameRate : $0.height > $1.height }
    guard let best = variants.first else { throw PlaybackFailure.unavailable }
    let json = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: Any]
    return PlaybackMedia(best.url, expires: json.flatMap(Self.expiry),
      isLive: false, variants: variants, headers: Self.mediaHeaders)
  }

  private func gql(_ query: String, variables: [String: String], credentials: TwitchCredentials) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(credentials.clientID, forHTTPHeaderField: "Client-ID")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
    request.setValue(credentials.deviceID, forHTTPHeaderField: "X-Device-Id")
    if let token = credentials.token { request.setValue("OAuth " + token, forHTTPHeaderField: "Authorization") }
    if let integrity = credentials.integrity { request.setValue(integrity, forHTTPHeaderField: "Client-Integrity") }
    let (bytes, response) = try await session.data(for: request)
    try Task.checkCancellation()
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 { throw TwitchFailure.signIn }
    if status == 403 { throw TwitchFailure.integrity }
    guard status == 200 else { throw PlaybackFailure.http(status) }
    guard bytes.count <= 2 * 1024 * 1024,
      let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else { throw PlaybackFailure.unavailable }
    if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
      let messages = errors.compactMap { $0["message"] as? String }.joined(separator: " ").lowercased()
      if messages.contains("integrity") { throw TwitchFailure.integrity }
      if messages.contains("unauthorized") { throw TwitchFailure.signIn }
      if messages.contains("forbidden") || messages.contains("restricted") { throw PlaybackFailure.restricted }
      throw PlaybackFailure.unavailable
    }
    guard let data = json["data"] as? [String: Any] else { throw PlaybackFailure.unavailable }
    return data
  }

  private static let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
  private static var supportedCodecs: [String] {
    hevc ? ["h264", "h265"] : ["h264"]
  }
  private static func expiry(_ json: [String: Any]) -> Date? {
    guard let seconds = json["expires"] as? Double, seconds.isFinite,
      seconds > 0, seconds < 253_402_300_800 else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }
  private static func supports(_ codecs: String) -> Bool {
    !codecs.split(separator: ",").contains { codec in
      let name = codec.trimmingCharacters(in: .whitespaces).lowercased()
      if name.hasPrefix("av01") || name.hasPrefix("av1") { return true }
      return (name.hasPrefix("hvc") || name.hasPrefix("hev") || name == "h265")
        && !hevc
    }
  }
}
