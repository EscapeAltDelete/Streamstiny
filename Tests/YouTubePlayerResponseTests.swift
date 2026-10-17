import Foundation

@main struct YouTubePlayerResponseTests {
  static func main() async throws {
    let cases: [(String, Bool?)] = [
      (#"{"videoDetails":{"videoId":"live","isLive":true}}"#, true),
      (#"{"videoDetails":{"videoId":"vod","isLive":false}}"#, false),
      (#"{"microformat":{"playerMicroformatRenderer":{"liveBroadcastDetails":{"isLiveNow":true}}}}"#, true),
      (#"{"microformat":{"playerMicroformatRenderer":{"liveBroadcastDetails":{"isLiveNow":false}}}}"#, false),
      (#"{"videoDetails":{"videoId":"ended","isLiveContent":true}}"#, nil),
      (#"{"videoDetails":{"videoId":"vod","isLive":false},"microformat":{"playerMicroformatRenderer":{"liveBroadcastDetails":{"isLiveNow":true}}}}"#, false),
      (#"{}"#, nil),
    ]
    let livePlaylist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n"
    let vodPlaylist = livePlaylist + "#EXT-X-ENDLIST\n"
    let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nvideo.m3u8\n"
    for (json, expected) in cases {
      let response = try JSONDecoder().decode(YouTubePlayerResponse.self, from: Data(json.utf8))
      precondition(response.isLive == expected, "Incorrect live status: \(json)")
      precondition(response.liveStatus(in: livePlaylist) == (expected ?? true))
      precondition(response.liveStatus(in: vodPlaylist) == (expected ?? false))
      precondition(response.liveStatus(in: master) == expected, "Master must not imply live")
    }
    print("Passed \(cases.count * 4) YouTube live/VOD metadata and playlist checks")
    TwitchPlaybackTests.run()
    try await PlaybackResolverTests.run()
  }
}
