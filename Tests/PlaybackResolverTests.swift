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
  static func prepare(_ replies: [String: (Int, String)]) {
    lock.lock()
    defer { lock.unlock() }
    self.replies = replies
    requests = 0
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
    Self.lock.lock()
    Self.requests += 1
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
      let query = URLComponents(url: media.url, resolvingAgainstBaseURL: false)!.queryItems!
      precondition(query.first { $0.name == "fast_bread" }?.value == String(enabled))
    }
    PlaybackProtocol.prepare(["gql.twitch.tv/gql": (401, "")])
    do {
      _ = try await resolver.resolve(StreamSource(provider: .twitch, key: "channel"))
      preconditionFailure("Authorization failures must not become retry loops")
    } catch TwitchFailure.signIn {}
    precondition(PlaybackProtocol.count == 1)

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
