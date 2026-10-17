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
    let key = url.host! + url.path
    Self.lock.lock()
    Self.requests += 1
    let client = request.value(forHTTPHeaderField: "X-YouTube-Client-Name") ?? ""
    let (status, body) = Self.replies[key + ":" + client] ?? Self.replies[key] ?? (500, "Unexpected request")
    Self.lock.unlock()
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
    let live = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,live\nsegment.ts\n"
    PlaybackProtocol.prepare(["video.example/master.m3u8": (200, master), "video.example/media.m3u8": (200, live)])
    let inspection = try await resolver.inspectHLS(url)
    precondition(inspection.live && inspection.variants?.count == 1)
    precondition(PlaybackProtocol.count == 2, "Inspect the master once and reuse its quality choices")
    PlaybackProtocol.prepare(["video.example/master.m3u8": (200, live + "#EXT-X-ENDLIST\n")])
    let recording = try await resolver.inspectHLS(url)
    precondition(!recording.live && recording.variants?.isEmpty == true && PlaybackProtocol.count == 1)
    PlaybackProtocol.prepare([:])
    let file = try await resolver.inspectHLS(URL(string: "https://video.example/video.mp4")!)
    precondition(!file.live && file.variants?.isEmpty == true && PlaybackProtocol.count == 0)
    let unavailable = try await resolver.inspectHLS(url)
    precondition(unavailable.live && unavailable.variants == nil, "Keep the decoder fallback after inspection fails")
    let cancelled = Task { try await resolver.inspectHLS(url) }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      preconditionFailure("Inspection must propagate cancellation")
    } catch is CancellationError {}

    let metadata: [(StreamSource.Provider, String, String, String, Bool?, Int)] = [
      (.kick, "channel", "kick.com/api/v2/channels/channel", #"{"livestream":{},"playback_url":"https://video.example/master.m3u8"}"#, true, 1),
      (.kickVod, "channel/id", "www.destiny.gg/api/kick/vod/channel/id", #"{"data":{"source":"https://video.example/master.m3u8"}}"#, false, 1),
      (.angelthump, "channel", "api.angelthump.com/v3/streams", #"[{"type":"live","user":{}}]"#, true, 2),
      (.rumble, "id", "rumble.com/embedJS/u3/", #"{"u":{"hls":"https://video.example/master.m3u8"}}"#, nil, 1),
      (.vimeo, "123", "player.vimeo.com/video/123/config", #"{"request":{"files":{"hls":{"default_cdn":"test","cdns":{"test":{"url":"https://video.example/master.m3u8"}}}}}}"#, nil, 1),
      (.facebook, "id", "www.facebook.com/id", #"{"browser_native_hd_url":"https://video.example/master.m3u8"}"#, nil, 1),
    ]
    for (provider, key, path, json, expectedLive, requests) in metadata {
      PlaybackProtocol.prepare([path: (200, json), "vigor.angelthump.com/channel/token": (200, #"{"token":"fixture","expiresIn":300}"#)])
      let media = try await resolver.resolve(StreamSource(provider: provider, key: key))
      precondition(media.isLive == expectedLive, "Incorrect live/VOD status: \(provider)")
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

    let grant = #"{"value":"{}","signature":"fixture"}"#
    let twitch = "{\"data\":{\"streamPlaybackAccessToken\":\(grant),\"videoPlaybackAccessToken\":\(grant)}}"
    for (provider, key, path, expectedLive) in [
      (StreamSource.Provider.twitch, "channel", "usher.ttvnw.net/api/v2/channel/hls/channel.m3u8", true),
      (.twitchVod, "v123", "usher.ttvnw.net/vod/123.m3u8", false),
    ] {
      PlaybackProtocol.prepare(["gql.twitch.tv/gql": (200, twitch), path: (200, master)])
      let media = try await resolver.resolve(StreamSource(provider: provider, key: key))
      precondition(media.isLive == expectedLive && media.variants?.count == 1)
      precondition(PlaybackProtocol.count == 2, "Twitch already supplies quality choices")
    }
    let clip = "{\"data\":{\"clip\":{\"playbackAccessToken\":\(grant),\"assets\":[{\"aspectRatio\":1.777,\"videoQualities\":[{\"quality\":\"1080\",\"sourceURL\":\"https://video.example/clip.mp4\",\"codecs\":\"avc1.640028,mp4a.40.2\"}]}]}}}"
    PlaybackProtocol.prepare(["gql.twitch.tv/gql": (200, clip)])
    let clipMedia = try await resolver.resolve(StreamSource(provider: .twitchClip, key: "clip"))
    precondition(clipMedia.isLive == false && clipMedia.variants?.first?.height == 1080 && PlaybackProtocol.count == 1)

    let player = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"video","isLive":true},"streamingData":{"hlsManifestUrl":"https://video.example/master.m3u8"}}"#
    PlaybackProtocol.prepare(["www.youtube.com/watch": (200, "var ytInitialPlayerResponse = " + player), "video.example/master.m3u8": (200, master)])
    let youtube = try await resolver.resolve(StreamSource(provider: .youtube, key: "video"))
    precondition(youtube.isLive == true && youtube.variants?.count == 1 && PlaybackProtocol.count == 2)
    // Reused bootstrap: one failed client must not hide the other client's media.
    PlaybackProtocol.prepare(["www.youtube.com/youtubei/v1/player:101": (403, ""), "www.youtube.com/youtubei/v1/player:3": (200, player), "video.example/master.m3u8": (200, master)])
    let fallback = try await resolver.resolve(StreamSource(provider: .youtube, key: "video"))
    precondition(fallback.isLive == true && fallback.variants?.count == 1)

    PlaybackProtocol.prepare(["player.vimeo.com/video/123/config": (200, #"{"request":{"files":{"progressive":[{"height":360,"url":"https://video.example/360.mp4"},{"height":1080,"url":"https://video.example/1080.mp4"},{"height":720,"url":"https://video.example/720.mp4"}]}}}"#)])
    let vimeo = try await resolver.resolve(StreamSource(provider: .vimeo, key: "123"))
    precondition(vimeo.url.path == "/1080.mp4" && PlaybackProtocol.count == 1)
    let progressive = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"recording","isLive":false},"streamingData":{"formats":[{"mimeType":"video/mp4","height":360,"url":"https://video.example/360.mp4"},{"mimeType":"video/mp4","height":1080,"url":"https://video.example/1080.mp4"},{"mimeType":"audio/mp4","url":"https://video.example/audio.mp4"}]}}"#
    PlaybackProtocol.prepare(["www.youtube.com/watch": (200, "var ytInitialPlayerResponse = " + progressive)])
    let freshResolver = PlaybackResolver(configuration: config)
    let video = try await freshResolver.resolve(StreamSource(provider: .youtube, key: "recording"))
    precondition(video.url.path == "/1080.mp4" && video.isLive == false && video.variants?.isEmpty == true)
    precondition(PlaybackProtocol.count == 1, "Progressive video needs no HLS discovery")
    print("Passed resolver regressions for every provider, HLS request reuse, cancellation, and offline/protected sources")
  }
}
