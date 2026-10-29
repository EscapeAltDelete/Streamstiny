import AVFoundation
import Foundation

@main struct PlaybackTests {
  static func main() async throws {
    for (input, provider, key) in [
      ("https://www.twitch.tv/channel", StreamSource.Provider.twitch, "channel"),
      ("https://player.twitch.tv/?channel=channel", .twitch, "channel"),
      ("https://kick.com/channel", .kick, "channel"),
      ("https://angelthump.com/channel", .angelthump, "channel"),
      ("https://www.youtube.com/@channel/live", .youtube, "@channel"),
      ("https://www.youtube.com/watch?v=live-id", .youtube, "live-id"),
      ("https://rumble.com/embed/id/", .rumble, "id"),
      ("https://vimeo.com/123", .vimeo, "123"),
      ("https://facebook.com/channel/live", .facebook, "channel/live"),
      ("https://video.example/live.m3u8", .direct, "https://video.example/live.m3u8"),
    ] {
      let source = try StreamSource.parse(input)
      precondition(source.provider == provider && source.key == key)
      let decoded = try JSONDecoder().decode(StreamSource.self, from: JSONEncoder().encode(source))
      precondition(decoded == source)
    }
    let base = URL(string: "https://video.example/master.m3u8")!
    let mixed = """
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1080x1920,FRAME-RATE=60,CODECS="hvc1.1.6.L123"
      portrait.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=2560x1440,FRAME-RATE=60,CODECS="hvc1.1.6.L123"
      landscape.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=12000000,RESOLUTION=1920x1080,FRAME-RATE=60,CODECS="avc1.640028"
      hd.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160,FRAME-RATE=60,CODECS="hvc1.1.6.L153"
      uhd.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=0x0,VIDEO="chunked",CODECS="hvc1.1.6.L153"
      source.m3u8
      """
    let ranked = HLSPlaylist.variants(mixed, base: base)
    precondition(ranked.map { $0.url.lastPathComponent } == ["source.m3u8", "uhd.m3u8", "landscape.m3u8", "hd.m3u8", "portrait.m3u8"])
    precondition(ranked[4].label == "1080p · Portrait · 60 fps · HEVC")
    precondition(ranked.first?.label == "Source")
    precondition(ranked[1].playbackURL(master: base) == ranked[1].url)
    let external = HLSVariant(url: ranked[1].url, width: 3840, height: 2160, bandwidth: 9000000, frameRate: 60, externalMedia: true)
    precondition(external.playbackURL(master: base) == base, "Keep alternate audio on its master")
    try ChatEncodingTests.run()
    try await ChatAssetsTests.run()
    ChatImageFormatTests.run()
    TwitchPlaybackTests.run()
    LowLatencyTests.run()
    precondition([0, 1, 2].compactMap { PlaybackStatus.retryDelay(attempt: $0) } == [1, 2, 4])
    precondition(PlaybackStatus.retryDelay(attempt: 3) == nil && PlaybackStatus.retryDelay(attempt: -1) == nil)
    for code in [403, 404, 408, 429, 500, 502, 503, 504] {
      precondition(PlaybackStatus.recoverable(PlaybackFailure.http(code)), "Transient/CDN failures are not stream-ended evidence")
    }
    precondition(!PlaybackStatus.recoverable(PlaybackFailure.offline) && !PlaybackStatus.recoverable(PlaybackFailure.restricted))
    precondition(!PlaybackStatus.recoverable(CancellationError()))
    precondition(PlaybackStatus.recovering.error == nil && PlaybackStatus.buffering.error == nil)
    precondition(PlaybackStatus.ended.error == "This stream has ended.")
    precondition(StreamBitrate(6_250_000)?.label == "6250 kbps")
    precondition(StreamBitrate(128_000)?.label == "128 kbps")
    precondition(StreamBitrate(1_234_000)?.label == "1234 kbps")
    precondition(StreamBitrate(128_000)?.title == "Estimated video bitrate")
    precondition(StreamBitrate(6_250_000) != StreamBitrate(4_000_000), "Changing video packet measurements must change the display")
    precondition(StreamBitrate(0) == nil && StreamBitrate(-1) == nil)
    var connectivity = PlaybackConnectivity()
    precondition(!connectivity.update(available: true), "An initial healthy path must not restart CDN retries")
    precondition(!connectivity.update(available: false))
    precondition(!connectivity.update(available: false))
    precondition(connectivity.update(available: true), "A genuine reconnection can resume bounded recovery")
    precondition(!connectivity.update(available: true), "Duplicate path notifications cannot create a retry loop")
    try await TwitchBackupTests.run()
    try await PlaybackResolverTests.run()
    print("Passed live-source parsing, persistence, and quality regressions")
  }
}
