import Foundation

// Resolve on the viewing device: signed Google Video URLs can be tied to its connection.
// Only read the player script's timestamp; no JavaScript runtime or signature deciphering.
actor YouTubeResolver {
  private struct Bootstrap {
    let visitor: String?
    let timestamp: Int?
    let created = Date()
  }

  private struct PlayerResponse: Decodable {
    struct Status: Decodable {
      let status: String
    }
    struct Details: Decodable {
      let videoId: String
      let isLive: Bool?
    }
    struct Streaming: Decodable {
      struct Format: Decodable {
        let url: String?
        let mimeType: String?
        let height: Int?
      }
      let hlsManifestUrl: String?
      let formats: [Format]?
    }
    let playabilityStatus: Status?
    let videoDetails: Details?
    let streamingData: Streaming?
  }

  private enum Client: CaseIterable {
    // Both expose ordinary live HLS without the iOS client's delayed token requirement.
    // Client versions follow yt-dlp's public YouTube extractor definitions.
    case vision, android

    var name: String { self == .vision ? "VISIONOS" : "ANDROID" }
    var version: String { self == .vision ? "1.02" : "21.26.364" }
    var identifier: String { self == .vision ? "101" : "3" }
    var userAgent: String {
      self == .vision
        ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        : "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip"
    }
    var context: [String: Any] {
      var client: [String: Any] = [
        "clientName": name, "clientVersion": version, "userAgent": userAgent,
        "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": 0,
      ]
      if self == .vision {
        client.merge([
          "deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
          "osName": "visionOS", "osVersion": "26.5.23O471",
        ]) { _, new in new }
      } else {
        client.merge(["androidSdkVersion": 30, "osName": "Android", "osVersion": "11"]) {
          _, new in new
        }
      }
      return ["client": client]
    }
  }

  private let session: URLSession
  private let decoder = JSONDecoder()
  private static let playerAssignment = try? NSRegularExpression(
    pattern: #"(?:ytInitialPlayerResponse\s*=|window\s*\[\s*["']ytInitialPlayerResponse["']\s*\]\s*=)\s*(\{)"#)
  private static let signatureTimestamp = try? NSRegularExpression(
    pattern: #"signatureTimestamp\s*[:=]\s*(\d{5,6})"#)
  private var bootstrap: Bootstrap?
  private var scriptTimestamp: (url: URL, value: Int)?

  init(session: URLSession) {
    self.session = session
    // Decline optional cookies so EU viewers receive public player data, not a consent page.
    if let cookie = HTTPCookie(properties: [
      .domain: ".youtube.com", .path: "/", .name: "SOCS", .value: "CAI", .secure: "TRUE",
    ]) {
      session.configuration.httpCookieStorage?.setCookie(cookie)
    }
  }

  func resolve(_ source: StreamSource) async throws -> PlaybackMedia {
    guard let pageURL = source.pageURL else { throw SourceError.invalid }
    var videoID = source.key
    var pageResponse: PlayerResponse?
    let reusedBootstrap = !source.isYouTubeChannel
      && bootstrap.map { $0.timestamp != nil && Date().timeIntervalSince($0.created) < 1800 } == true

    if !reusedBootstrap {
      let page = try await loadPage(pageURL)
      pageResponse = page.player
      if source.isYouTubeChannel {
        guard let identifier = page.player?.videoDetails?.videoId else {
          if let status = page.player?.playabilityStatus { throw failure(status) }
          throw PlaybackFailure.offline
        }
        videoID = identifier
      }
      bootstrap = page.bootstrap
    }
    guard let context = bootstrap else { throw PlaybackFailure.unavailable }

    // A cached session can expire before its normal TTL. Re-bootstrap once on failure.
    do {
      return try await resolve(videoID: videoID, bootstrap: context, page: pageResponse)
    } catch {
      try Task.checkCancellation()
      guard reusedBootstrap else { throw error }
      let page = try await loadPage(pageURL)
      bootstrap = page.bootstrap
      return try await resolve(videoID: videoID, bootstrap: page.bootstrap, page: page.player)
    }
  }

  private func resolve(videoID: String, bootstrap: Bootstrap, page: PlayerResponse?)
    async throws -> PlaybackMedia
  {
    // Preserve directly supplied media, including ordinary YouTube videos.
    if let page, page.videoDetails?.videoId == videoID,
      let media = try? await playable(page)
    {
      try Task.checkCancellation()
      return media
    }
    var lastError: Error = PlaybackFailure.unavailable
    for client in Client.allCases {
      try Task.checkCancellation()
      do {
        let response = try await player(videoID, client: client, bootstrap: bootstrap)
        guard response.videoDetails?.videoId == videoID else {
          throw response.playabilityStatus.map(failure) ?? PlaybackFailure.unavailable
        }
        return try await playable(response)
      } catch {
        try Task.checkCancellation()
        lastError = error
      }
    }
    throw lastError
  }

  private func loadPage(_ url: URL) async throws -> (player: PlayerResponse?, bootstrap: Bootstrap) {
    let html = String(decoding: try await fetch(URLRequest(url: url)), as: UTF8.self)
    let player = pagePlayer(in: html)
    let context = PlaybackResolver.jsonObject(in: html, following: "\"INNERTUBE_CONTEXT\":")
    let client = context?["client"] as? [String: Any]
    let visitor = client?["visitorData"] as? String
    let script = PlaybackResolver.jsonString(in: html, named: "PLAYER_JS_URL")
      ?? PlaybackResolver.jsonString(in: html, named: "jsUrl")
    var timestamp: Int?
    let suppliedMedia = player?.streamingData?.hlsManifestUrl != nil
      || (player?.streamingData?.formats?.contains {
        $0.url != nil && ($0.mimeType ?? "").hasPrefix("video/mp4")
      } == true
        && player?.videoDetails?.isLive != true)
    if !suppliedMedia, player?.videoDetails != nil,
      let script, let url = URL(string: script, relativeTo: url)?.absoluteURL,
      url.scheme == "https", url.host == "www.youtube.com",
      url.path.hasPrefix("/s/player/"), url.pathExtension == "js"
    {
      if let cached = scriptTimestamp, cached.url == url {
        timestamp = cached.value
      } else {
        do {
          let text = String(decoding: try await fetch(URLRequest(url: url)), as: UTF8.self)
          timestamp = Self.timestamp(in: text)
          if let timestamp { scriptTimestamp = (url, timestamp) }
        } catch {
          try Task.checkCancellation()
          // Some public HLS responses do not need a script timestamp.
        }
      }
    }
    return (player, Bootstrap(visitor: visitor, timestamp: timestamp))
  }

  private func pagePlayer(in html: String) -> PlayerResponse? {
    // The name also appears in script strings before the actual JSON assignment.
    guard let regex = Self.playerAssignment else { return nil }
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let range = Range(match.range(at: 1), in: html),
        let data = PlaybackResolver.jsonData(in: html, from: range.lowerBound),
        let player = try? decoder.decode(PlayerResponse.self, from: data),
        player.playabilityStatus != nil
      else { continue }
      return player
    }
    return nil
  }

  private func player(_ videoID: String, client: Client, bootstrap: Bootstrap)
    async throws -> PlayerResponse
  {
    var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
    if let timestamp = bootstrap.timestamp { playback["signatureTimestamp"] = timestamp }
    let body: [String: Any] = [
      "context": client.context, "videoId": videoID,
      "playbackContext": ["contentPlaybackContext": playback],
      "contentCheckOk": true, "racyCheckOk": true,
    ]
    var request = URLRequest(
      url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(client.identifier, forHTTPHeaderField: "X-YouTube-Client-Name")
    request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
    request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
    request.setValue(bootstrap.visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
    let data = try await fetch(request)
    return try decoder.decode(PlayerResponse.self, from: data)
  }

  private func playable(_ response: PlayerResponse) async throws -> PlaybackMedia {
    guard let status = response.playabilityStatus, status.status == "OK" else {
      throw response.playabilityStatus.map(failure) ?? PlaybackFailure.unavailable
    }
    if let address = response.streamingData?.hlsManifestUrl, let url = Self.mediaURL(address) {
      let text = String(decoding: try await fetch(URLRequest(url: url)), as: UTF8.self)
      guard text.hasPrefix("#EXTM3U") else { throw PlaybackFailure.unavailable }
      let variants = HLSPlaylist.variants(text, base: url)
      guard !variants.isEmpty || HLSPlaylist.isLive(text) != nil else {
        throw PlaybackFailure.unavailable
      }
      return PlaybackMedia(
        url, expires: Self.expiry(url), isLive: response.videoDetails?.isLive,
        variants: variants)
    }
    // Progressive formats cannot replace an ongoing livestream's HLS transport.
    guard response.videoDetails?.isLive != true else { throw PlaybackFailure.unavailable }
    let formats = (response.streamingData?.formats ?? []).filter {
      ($0.mimeType ?? "").hasPrefix("video/mp4") && $0.url != nil
    }.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
    guard let address = formats.first?.url, let url = Self.mediaURL(address) else {
      throw PlaybackFailure.unavailable
    }
    return PlaybackMedia(url, expires: Self.expiry(url), isLive: false)
  }

  private func fetch(_ request: URLRequest) async throws -> Data {
    try Task.checkCancellation()
    var request = request
    request.timeoutInterval = 10
    if request.value(forHTTPHeaderField: "User-Agent") == nil {
      request.setValue(Client.vision.userAgent, forHTTPHeaderField: "User-Agent")
    }
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw PlaybackFailure.http((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    guard data.count <= 8 * 1024 * 1024 else { throw PlaybackFailure.unavailable }
    return data
  }

  private func failure(_ status: PlayerResponse.Status) -> Error {
    if status.status == "LIVE_STREAM_OFFLINE" { return PlaybackFailure.offline }
    if status.status == "LOGIN_REQUIRED" || status.status == "AGE_CHECK_REQUIRED" {
      return PlaybackFailure.restricted
    }
    return PlaybackFailure.unavailable
  }

  private static func mediaURL(_ address: String) -> URL? {
    guard let url = URL(string: address), url.scheme == "https", let host = url.host,
      host.hasSuffix(".googlevideo.com"), url.user == nil, url.password == nil
    else { return nil }
    return url
  }

  private static func timestamp(in script: String) -> Int? {
    guard let regex = signatureTimestamp,
      let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
      let range = Range(match.range(at: 1), in: script)
    else { return nil }
    return Int(script[range])
  }

  private static func expiry(_ url: URL) -> Date? {
    let segments = url.path.split(separator: "/")
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name == "expire" })?.value
    let value = segments.firstIndex(of: "expire").flatMap { index in
      index + 1 < segments.count ? Double(segments[index + 1]) : nil
    } ?? query.flatMap(Double.init)
    guard let value, value.isFinite, value > 0 else { return nil }
    return Date(timeIntervalSince1970: value)
  }
}
