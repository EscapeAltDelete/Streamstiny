import Foundation

enum TwitchPlaybackTests {
  static func run() {
    let clean = """
      #EXTM3U
      #EXT-X-TARGETDURATION:2
      #EXT-X-MEDIA-SEQUENCE:100
      #EXT-X-PROGRAM-DATE-TIME:2026-10-17T10:00:00.000Z
      #EXTINF:2,live
      https://cdn.example/100.ts
      #EXTINF:2,live
      https://cdn.example/101.ts
      #EXTINF:2,live
      https://cdn.example/102.ts
      """ + "\n"
    func withTag(_ tag: String) -> String {
      clean.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:100", with: "#EXT-X-MEDIA-SEQUENCE:100\n" + tag)
    }
    let primary = TwitchAdPlaylist(clean)!
    precondition(!primary.hasAds && primary.segments.count == 3)
    precondition(primary.segments.map(\.sequence) == [100, 101, 102])
    precondition(primary.cleanSuffix?.segments.count == 3)

    let range = #"#EXT-X-DATERANGE:ID="stitched-ad-1",CLASS="twitch-stitched-ad",START-DATE="2026-10-17T10:00:02Z",END-DATE="2026-10-17T10:00:04Z""#
    let dated = TwitchAdPlaylist(withTag(range))!
    precondition(dated.segments.map(\.isAd) == [false, true, false])
    precondition(dated.cleanSuffix?.segments.first?.sequence == 102)
    let duration = range.replacingOccurrences(of: #"END-DATE="2026-10-17T10:00:04Z""#, with: "DURATION=2")
    precondition(TwitchAdPlaylist(withTag(duration))!.segments.map(\.isAd) == [false, true, false])
    precondition(TwitchAdPlaylist(withTag(#"#EXT-X-DATERANGE:ID="stitched-ad-1",CLASS="twitch-stitched-ad""#))!.segments.allSatisfy(\.isAd))
    precondition(!TwitchAdPlaylist(withTag(#"#EXT-X-DATERANGE:ID="trigger",CLASS="twitch-trigger""#))!.hasAds)
    precondition(!TwitchAdPlaylist(withTag(#"#EXT-X-DATERANGE:ID="other",CLASS="chapter""#))!.hasAds)

    let cue = clean.replacingOccurrences(of: "#EXTINF:2,live\nhttps://cdn.example/101.ts", with: "#EXT-X-CUE-OUT:2\n#EXTINF:2,live\nhttps://cdn.example/101.ts\n#EXT-X-CUE-IN")
    precondition(TwitchAdPlaylist(cue)!.segments.map(\.isAd) == [false, true, false])
    precondition(TwitchAdPlaylist(clean.replacingOccurrences(of: "101.ts", with: "adsquared/101.ts"))!.hasAds)
    precondition(TwitchAdPlaylist(clean.replacingOccurrences(of: ",live", with: ",advertisement"))!.cleanSuffix == nil)
    precondition(TwitchAdPlaylist(withTag(#"#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key""#))!.segments.allSatisfy(\.encrypted))
    precondition(TwitchAdPlaylist(withTag("#EXT-X-KEY:METHOD=NONE"))!.segments.allSatisfy { !$0.encrypted })
    precondition(TwitchAdPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nvideo.m3u8\n") == nil)
    precondition(TwitchAdPlaylist(clean.replacingOccurrences(of: "#EXTINF:2", with: "#EXTINF:0")) == nil)

    var timeline = TwitchAdTimeline()
    let first = timeline.render(primary, backup: nil, origin: "primary")
    precondition(timeline.render(primary, backup: nil, origin: "primary") == first)
    let allAds = TwitchAdPlaylist(withTag("#EXT-X-CUE-OUT:6"))!
    precondition(timeline.render(allAds, backup: nil, origin: "primary", force: true) == first)
    precondition(timeline.waiting)
    var fresh = TwitchAdTimeline()
    let fallback = fresh.render(allAds, backup: primary, origin: "backup", force: true)
    precondition(!fresh.waiting && fallback.contains("https://cdn.example/100.ts"))
    precondition(!fallback.contains("#EXT-X-CUE-OUT"))
    precondition(fallback.components(separatedBy: "#EXTINF:").count == 4)
    let encryptedAds = TwitchAdPlaylist(withTag("#EXT-X-CUE-OUT:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"https://cdn.example/key\""))!
    var protected = TwitchAdTimeline()
    _ = protected.render(encryptedAds, backup: primary, origin: "backup", force: true)
    precondition(protected.waiting, "Never mix an encrypted primary with a backup")
    var ended = TwitchAdTimeline()
    precondition(ended.render(TwitchAdPlaylist(clean + "#EXT-X-ENDLIST\n")!, backup: nil, origin: "primary").hasSuffix("#EXT-X-ENDLIST\n"))

    let prefetch = clean + "#EXT-X-TWITCH-PREFETCH:https://cdn.example/103.ts\n#EXT-X-TWITCH-PREFETCH:https://cdn.example/104.ts\n"
    let expanded = TwitchLowLatency.expand(prefetch)
    let lowLatency = TwitchAdPlaylist(expanded)!
    precondition(lowLatency.segments.count == 5 && lowLatency.segments.last?.sequence == 104)
    precondition(lowLatency.segments.last?.duration == 2 && !lowLatency.hasAds)
    precondition(!expanded.contains("#EXT-X-TWITCH-PREFETCH"), "Expose open segments to the HLS reader")
    precondition(TwitchLowLatency.expand(clean) == clean)
    precondition(TwitchLowLatency.expand(prefetch + "#EXT-X-ENDLIST\n") == prefetch + "#EXT-X-ENDLIST\n")
    let encrypted = prefetch.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:100", with: "#EXT-X-MEDIA-SEQUENCE:100\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"")
    precondition(TwitchLowLatency.expand(encrypted) == encrypted)
    let advertising = prefetch.replacingOccurrences(of: ",live", with: ",advertisement")
    precondition(TwitchLowLatency.expand(advertising) == advertising, "Do not speculate through ads")
    let boundary = clean + "#EXT-X-DISCONTINUITY\n#EXT-X-TWITCH-PREFETCH:https://cdn.example/103.ts\n"
    precondition(TwitchLowLatency.expand(boundary) == boundary, "Wait for confirmation across an unknown ad boundary")
    let futureAd = prefetch.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:100", with: "#EXT-X-MEDIA-SEQUENCE:100\n#EXT-X-DATERANGE:ID=\"stitched-ad-2\",CLASS=\"twitch-stitched-ad\",START-DATE=\"2026-10-17T10:00:06Z\",DURATION=4")
    let expandedAd = TwitchAdPlaylist(TwitchLowLatency.expand(futureAd))!
    precondition(expandedAd.segments.suffix(2).allSatisfy(\.isAd), "Apply ad ranges to prefetched video too")
    var continuous = TwitchAdTimeline()
    let initial = continuous.render(lowLatency, backup: nil, origin: "primary")
    let confirmed = TwitchAdPlaylist(expanded.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:100", with: "#EXT-X-MEDIA-SEQUENCE:101").replacingOccurrences(of: "#EXTINF:2,live\nhttps://cdn.example/100.ts\n", with: ""))!
    precondition(continuous.render(confirmed, backup: nil, origin: "primary") == initial, "Do not replay a prefetched segment when it becomes complete")
    print("Passed Twitch ad/timeline/encryption and low-latency prefetch regressions")
  }
}
