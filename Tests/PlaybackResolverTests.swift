import Foundation

// Account UI and Keychain are outside these network tests; use guest credentials.
struct TwitchCredentials: Sendable {
  let token: String? = nil
  let deviceID = "playback-tests"
  let integrity: String? = nil
  let clientID = TwitchResolver.clientID
}
@MainActor final class TwitchAccount {
  static let shared = TwitchAccount()
  func credentials() -> TwitchCredentials { TwitchCredentials() }
  func invalidate(_ token: String?) async {}
  func refreshIntegrity() async -> TwitchCredentials? { nil }
}

private final class PlaybackProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var replies: [String: (Int, String)] = [:]
  private static var requests = 0
  private static var bodies: [Data] = []
  static func prepare(_ replies: [String: (Int, String)]) {
    lock.lock()
    defer { lock.unlock() }
    self.replies = replies
    requests = 0
    bodies = []
  }
  static var variables: [[String: String]] {
    lock.lock()
    defer { lock.unlock() }
    return bodies.compactMap {
      (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["variables"] as? [String: String]
    }
  }
  static var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    let key = url.host! + URLComponents(url: url, resolvingAgainstBaseURL: false)!.path
    var body = request.httpBody
    if body == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
      body = data
    }
    Self.lock.lock()
    Self.requests += 1
    if let body { Self.bodies.append(body) }
    let client = request.value(forHTTPHeaderField: "X-YouTube-Client-Name") ?? ""
    let reply = Self.replies[key + ":" + client] ?? Self.replies[key]
    Self.lock.unlock()
    guard let (status, body) = reply else { fatalError("Unexpected fixture request: \(key)") }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    self.client?.urlProtocol(self, didLoad: Data(body.utf8))
    self.client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

enum PlaybackResolverTests {
  static func run() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PlaybackProtocol.self]
    let resolver = PlaybackResolver(configuration: config)
    let url = URL(string: "https://video.example/master.m3u8")!
    let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,CODECS=\"avc1.64001F,mp4a.40.2\"\nmedia.m3u8\n"
    PlaybackProtocol.prepare(["video.example/master.m3u8": (200, master)])
    let choices = try await resolver.variants(at: url)
    precondition(choices.count == 1 && choices[0].url.path == "/media.m3u8")
    precondition(PlaybackProtocol.count == 1, "Quality discovery only downloads the master")
    let live = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:2,live\n100.ts\n"
    for ended in [false, true] {
      PlaybackProtocol.prepare(["video.example/master.m3u8": (200, master),
        "video.example/media.m3u8": (200, live + (ended ? "#EXT-X-ENDLIST\n" : ""))])
      let verified = try await resolver.ended(at: url)
      precondition(verified == ended && PlaybackProtocol.count == 2)
    }
    for status in [403, 404, 429, 500, 503] {
      PlaybackProtocol.prepare(["video.example/master.m3u8": (status, "")])
      do { _ = try await resolver.ended(at: url); preconditionFailure("HTTP failures must not become authoritative stream termination") }
      catch PlaybackFailure.http(let code) { precondition(code == status) }
    }
    for invalid in ["", "<html>Temporary error</html>", "#EXTM3U\n#EXT-X-ENDLIST\n"] {
      PlaybackProtocol.prepare(["video.example/master.m3u8": (200, invalid)])
      do { _ = try await resolver.ended(at: url); preconditionFailure("Only a validated media playlist can confirm an end") }
      catch PlaybackFailure.unavailable {}
    }
    PlaybackProtocol.prepare([:])
    let none = try await resolver.variants(at: URL(string: "https://video.example/no-playlist")!)
    precondition(none.isEmpty && PlaybackProtocol.count == 0)
    PlaybackProtocol.prepare(["video.example/master.m3u8": (500, "")])
    do {
      _ = try await resolver.variants(at: url)
      preconditionFailure("Failed playlist fetches must remain retryable errors")
    } catch PlaybackFailure.unavailable {}

    let metadata: [(StreamSource.Provider, String, String, String, Int)] = [
      (.kick, "channel", "kick.com/api/v2/channels/channel", #"{"livestream":{},"playback_url":"https://video.example/master.m3u8"}"#, 1),
      (.angelthump, "channel", "api.angelthump.com/v3/streams", #"[{"type":"live","user":{}}]"#, 2),
      (.rumble, "id", "rumble.com/embedJS/u3/", #"{"u":{"hls":"https://video.example/master.m3u8"}}"#, 1),
      (.vimeo, "123", "player.vimeo.com/video/123/config", #"{"request":{"files":{"hls":{"default_cdn":"test","cdns":{"test":{"url":"https://video.example/master.m3u8"}}}}}}"#, 1),
      (.facebook, "id", "www.facebook.com/id", #"{"playable_url":"https://video.example/master.m3u8"}"#, 1),
    ]
    for (provider, key, path, json, requests) in metadata {
      PlaybackProtocol.prepare([path: (200, json), "vigor.angelthump.com/channel/token": (200, #"{"token":"fixture"}"#)])
      let media = try await resolver.resolve(StreamSource(provider: provider, key: key))
      precondition(media.url.scheme == "https" && media.url.pathExtension == "m3u8")
      precondition(PlaybackProtocol.count == requests, "Unexpected metadata requests: \(provider)")
    }
    PlaybackProtocol.prepare([:])
    _ = try await resolver.resolve(StreamSource(provider: .direct, key: url.absoluteString))
    precondition(PlaybackProtocol.count == 0)
    for (provider, key, path, json) in [
      (StreamSource.Provider.kick, "channel", "kick.com/api/v2/channels/channel", #"{"livestream":null}"#),
      (.angelthump, "channel", "api.angelthump.com/v3/streams", "[]"),
    ] {
      PlaybackProtocol.prepare([path: (200, json)])
      do {
        _ = try await resolver.resolve(StreamSource(provider: provider, key: key))
        preconditionFailure("Offline channels must stop before requesting media")
      } catch PlaybackFailure.offline {}
      precondition(PlaybackProtocol.count == 1)
    }
    for body in [#"{"error":"temporarily unavailable"}"#, #"[{"error":"upstream unavailable"}]"#] {
      PlaybackProtocol.prepare(["api.angelthump.com/v3/streams": (200, body)])
      do {
        _ = try await resolver.resolve(StreamSource(provider: .angelthump, key: "channel"))
        preconditionFailure("Malformed provider state must remain recoverable")
      } catch PlaybackFailure.unavailable {}
    }
    PlaybackProtocol.prepare(["api.angelthump.com/v3/streams": (200, #"[{"type":"live","user":{"password_protect":true}}]"#)])
    do {
      _ = try await resolver.resolve(StreamSource(provider: .angelthump, key: "channel"))
      preconditionFailure("Protected channels must not request a public token")
    } catch PlaybackFailure.restricted {}
    precondition(PlaybackProtocol.count == 1)

    let twitch = #"{"data":{"streamPlaybackAccessToken":{"value":"{}","signature":"fixture"}}}"#
    PlaybackProtocol.prepare(["gql.twitch.tv/gql": (200, twitch), "usher.ttvnw.net/api/v2/channel/hls/channel.m3u8": (200, master)])
    let previous = UserDefaults.standard.object(forKey: "twitchLowLatency")
    defer { UserDefaults.standard.set(previous, forKey: "twitchLowLatency") }
    for enabled in [false, true] {
      UserDefaults.standard.set(enabled, forKey: "twitchLowLatency")
      PlaybackProtocol.prepare(["gql.twitch.tv/gql": (200, twitch), "usher.ttvnw.net/api/v2/channel/hls/channel.m3u8": (200, master)])
      let media = try await resolver.resolve(StreamSource(provider: .twitch, key: "channel"))
      precondition(media.variants?.count == 1 && PlaybackProtocol.count == 2)
      precondition(PlaybackProtocol.variables.first?["playerType"] == "popout")
      precondition(PlaybackProtocol.variables.first?["platform"] == "web")
      let query = URLComponents(url: media.url, resolvingAgainstBaseURL: false)!.queryItems!
      precondition(query.first { $0.name == "fast_bread" }?.value == String(enabled))
    }
    for context in ["embed", "popout", "site", "mobile_web", "autoplay"] {
      PlaybackProtocol.prepare(["gql.twitch.tv/gql": (200, twitch), "usher.ttvnw.net/api/v2/channel/hls/channel.m3u8": (200, master)])
      let media = try await resolver.twitchAlternative(StreamSource(provider: .twitch, key: "channel"), playerType: context)
      precondition(media.variants?.count == 1 && PlaybackProtocol.count == 2)
      precondition(PlaybackProtocol.variables.first?["playerType"] == context)
      precondition(PlaybackProtocol.variables.first?["platform"] == (context == "autoplay" ? "android" : "web"))
    }
    PlaybackProtocol.prepare(["gql.twitch.tv/gql": (401, "")])
    do {
      _ = try await resolver.resolve(StreamSource(provider: .twitch, key: "channel"))
      preconditionFailure("Authorization failures must not become retry loops")
    } catch TwitchFailure.signIn {}
    precondition(PlaybackProtocol.count == 1)

    // Exercise the real gateway cache: a fallback must be usable immediately,
    // then upgraded when a matching clean rendition becomes available.
    do {
      let previousBlocking = UserDefaults.standard.object(forKey: "twitchAdBlocking")
      UserDefaults.standard.set(true, forKey: "twitchAdBlocking")
      defer { UserDefaults.standard.set(previousBlocking, forKey: "twitchAdBlocking") }
      let primaryURL = URL(string: "https://video.ttvnw.net/primary.m3u8")!
      let primary = HLSVariant(url: primaryURL, width: 1920, height: 1080,
        bandwidth: 6_000_000, frameRate: 60, externalMedia: false, codecs: "avc1.640028,mp4a.40.2")
      let backups = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,FRAME-RATE=60,CODECS="avc1.640028,mp4a.40.2"
        https://video.ttvnw.net/hd.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360,FRAME-RATE=30,CODECS="avc1.42001E,mp4a.40.2"
        https://video.ttvnw.net/sd.m3u8
        """
      func media(_ name: String, _ sequence: Int, ad: Bool = false) -> String {
        "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:\(sequence)\n#EXTINF:2,\(ad ? "advertisement" : "live")\nhttps://video.ttvnw.net/\(name).ts\n"
      }
      func fixtures(hd: String) -> [String: (Int, String)] {
        ["gql.twitch.tv/gql": (200, twitch),
         "usher.ttvnw.net/api/v2/channel/hls/channel.m3u8": (200, backups),
         "video.ttvnw.net/primary.m3u8": (200, media("ad", 100, ad: true)),
         "video.ttvnw.net/hd.m3u8": (200, hd),
         "video.ttvnw.net/sd.m3u8": (200, media("sd", 100))]
      }
      PlaybackProtocol.prepare(fixtures(hd: media("hd-ad", 100, ad: true)))
      let session = PlaylistSession(source: StreamSource(provider: .twitch, key: "channel"),
        variants: [primary], resolver: resolver, configuration: config)
      let local = await session.route(primaryURL, port: 12345)
      let fallback = await session.response(path: local.path)
      precondition(fallback.status == 200 && fallback.text.contains("/sd.ts") && !fallback.text.contains("/ad.ts"))
      let initialRequests = PlaybackProtocol.count
      let cached = await session.response(path: local.path)
      precondition(cached.text == fallback.text && PlaybackProtocol.count == initialRequests + 2,
        "A warm backup reuses its grant and only fetches primary and backup manifests")
      try await Task.sleep(for: .milliseconds(5100))
      PlaybackProtocol.prepare(fixtures(hd: media("hd", 200)))
      let continuing = await session.response(path: local.path)
      precondition(continuing.text.contains("/sd.ts"), "Playback continues while the upgrade is searched")
      var upgraded = false
      for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(25))
        let result = await session.response(path: local.path)
        if result.text.contains("/hd.ts") {
          precondition(result.text.contains("#EXT-X-DISCONTINUITY"))
          upgraded = true; break
        }
      }
      precondition(upgraded, "A clean cached 360p backup must not lock playback below 1080p60")
      await session.stop()
      print("Passed Twitch gateway warm-cache reuse and live fallback-to-1080p60 upgrade regressions")
    }

    do {
      let keys = ["kickLowLatency", "twitchAdBlocking"]
      let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
      defer { for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) } }
      UserDefaults.standard.set(true, forKey: "twitchAdBlocking")
      let masterURL = URL(string: "https://test.playback.live-video.net/master.m3u8")!
      let kickMaster = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,FRAME-RATE=60\nhttps://test.playlist.live-video.net/hd.m3u8\n"
      let kickMedia = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:4.167,advertisement
        https://test.hls.live-video.net/100.ts
        #EXT-X-PREFETCH:https://test.hls.live-video.net/101.ts
        """ + "\n"
      for enabled in [false, true] {
        UserDefaults.standard.set(enabled, forKey: "kickLowLatency")
        PlaybackProtocol.prepare([
          "test.playback.live-video.net/master.m3u8": (200, kickMaster),
          "test.playlist.live-video.net/hd.m3u8": (200, kickMedia),
        ])
        let session = PlaylistSession(source: StreamSource(provider: .kick, key: "channel"),
          variants: [], resolver: resolver, configuration: config)
        let route = await session.route(masterURL, port: 12345)
        let root = await session.response(path: route.path)
        let child = URL(string: root.text.components(separatedBy: .newlines).first { $0.hasPrefix("http://127.0.0.1:") }!)!
        let media = await session.response(path: child.path)
        precondition(root.status == 200 && media.status == 200)
        precondition(media.text.contains("advertisement"), "Twitch ad blocking never filters Kick media")
        precondition(media.text.contains("https://test.hls.live-video.net/101.ts"))
        precondition(media.text.contains("#EXT-X-PREFETCH:") == !enabled)
        precondition(media.text.components(separatedBy: "#EXTINF:").count == (enabled ? 3 : 2))
        precondition(!media.text.contains("127.0.0.1"), "Media goes directly to the CDN without whole-segment proxy buffering")
        precondition(PlaybackProtocol.count == 2)
        let waiting = await session.waiting
        precondition(!waiting)
        for address in ["https://video.ttvnw.net/foreign.m3u8", "https://test.playlist.live-video.net.evil.example/foreign.m3u8",
          "http://test.playlist.live-video.net/foreign.m3u8", "https://user:password@test.playlist.live-video.net/foreign.m3u8"] {
          let invalid = await session.route(URL(string: address)!, port: 12345)
          let rejected = await session.response(path: invalid.path)
          precondition(rejected.status == 502 && PlaybackProtocol.count == 2, "Reject invalid provider URLs before making a request")
        }
        await session.stop()
      }
      print("Passed Kick gateway toggles, master routing, direct media, provider isolation, and URL-validation regressions")
    }

    let player = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"video"},"streamingData":{"hlsManifestUrl":"https://manifest.googlevideo.com/master.m3u8"}}"#
    PlaybackProtocol.prepare(["www.youtube.com/watch": (200, "var ytInitialPlayerResponse = " + player), "manifest.googlevideo.com/master.m3u8": (200, master)])
    let youtube = try await resolver.resolve(StreamSource(provider: .youtube, key: "video"))
    precondition(youtube.variants?.count == 1 && PlaybackProtocol.count == 2)
    PlaybackProtocol.prepare(["www.youtube.com/youtubei/v1/player:101": (403, ""), "www.youtube.com/youtubei/v1/player:3": (200, player), "manifest.googlevideo.com/master.m3u8": (200, master)])
    let fallback = try await resolver.resolve(StreamSource(provider: .youtube, key: "video"))
    precondition(fallback.variants?.count == 1, "One failed client must not hide the other client's media")

    // Cancellation may finish URLProtocol callbacks after the task returns; test it last.
    PlaybackProtocol.prepare(["video.example/master.m3u8": (200, master)])
    let cancelled = Task { try await resolver.variants(at: url) }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      preconditionFailure("Playlist requests must propagate cancellation")
    } catch is CancellationError {} catch let error as URLError {
      precondition(error.code == .cancelled)
    }
    print("Passed all-provider resolver, request-count, authorization, offline, and cancellation regressions")
  }
}
