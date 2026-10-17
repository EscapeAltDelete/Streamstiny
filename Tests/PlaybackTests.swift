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
    func range(_ start: Double, _ length: Double) -> CMTimeRange {
      CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
    }
    precondition(PlaybackTiming(current: 1, loaded: [range(4, 2), range(0, 2), range(2, 2)]).buffered == 5)
    precondition(PlaybackTiming(current: 1, loaded: [range(4, 2), range(0, 2)]).buffered == 1)
    precondition(PlaybackTiming(current: .nan, loaded: []).buffered == 0)
    precondition(PlaybackTiming(current: 2, loaded: [range(0, 1)]).buffered == 0)
    TwitchPlaybackTests.run()
    try await PlaybackResolverTests.run()
    print("Passed live-source parsing, persistence, and contiguous-buffer regressions")
  }
}
