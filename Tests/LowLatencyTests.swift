import Foundation

enum LowLatencyTests {
  static func run() {
    let keys = ["twitchLowLatency", "kickLowLatency", "youtubeLowLatency", "angelthumpLowLatency"]
    let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
    defer { for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) } }
    UserDefaults.standard.set(false, forKey: "youtubeLowLatency")
    for enabled in [false, true] {
      UserDefaults.standard.set(enabled, forKey: "kickLowLatency")
      UserDefaults.standard.set(!enabled, forKey: "twitchLowLatency")
      precondition(HLSLowLatency.enabled(for: .kick) == enabled)
      precondition(HLSLowLatency.enabled(for: .twitch) == !enabled)
      precondition(!HLSLowLatency.enabled(for: .youtube))
    }
    UserDefaults.standard.set(true, forKey: "youtubeLowLatency")
    precondition(HLSLowLatency.enabled(for: .youtube) && HLSLowLatency.enabled(for: .kick))
    precondition(!HLSLowLatency.enabled(for: .twitch) && !HLSLowLatency.enabled(for: .direct))
    for enabled in [false, true] {
      UserDefaults.standard.set(enabled, forKey: "angelthumpLowLatency")
      precondition(HLSLowLatency.enabled(for: .angelthump) == enabled)
    }
    let complete = """
      #EXTM3U
      #EXT-X-TARGETDURATION:6
      #EXT-X-MEDIA-SEQUENCE:100
      #EXTINF:4.167,live
      100.ts
      #EXTINF:4.167,live
      101.ts
      """ + "\n"
    let pending = "#EXT-X-PREFETCH:102.ts\n#EXT-X-PREFETCH:103.ts\n"
    let input = complete + pending
    let expanded = HLSLowLatency.expand(input, provider: .kick)
    let playlist = TwitchAdPlaylist(expanded)!
    precondition(playlist.segments.map(\.sequence) == [100, 101, 102, 103])
    precondition(playlist.segments.allSatisfy { $0.duration == 4.167 }, "Use media durations, not the six-second upper bound")
    precondition(playlist.segments.suffix(2).map { $0.lines.last! } == ["102.ts", "103.ts"])
    precondition(!expanded.contains("#EXT-X-PREFETCH:"))
    precondition(HLSLowLatency.expand(input, provider: .youtube) == input)
    precondition(HLSLowLatency.expand(input, provider: .angelthump) == input, "AngelThump must not acquire unverified prefetch support")
    precondition(HLSLowLatency.expand(input, provider: .twitch) == input, "Provider tags must not be confused")
    precondition(HLSLowLatency.expand(complete, provider: .kick) == complete)
    let duplicate = HLSLowLatency.expand(complete + "#EXT-X-PREFETCH:101.ts\n" + pending + pending, provider: .kick)
    precondition(TwitchAdPlaylist(duplicate)!.segments.count == 4, "Never append already complete or duplicate prefetch URLs")
    let confirmed = """
      #EXTM3U
      #EXT-X-TARGETDURATION:6
      #EXT-X-MEDIA-SEQUENCE:101
      #EXTINF:4.167,live
      101.ts
      #EXTINF:4.167,live
      102.ts
      #EXT-X-PREFETCH:103.ts
      #EXT-X-PREFETCH:104.ts
      """ + "\n"
    let rolling = TwitchAdPlaylist(HLSLowLatency.expand(confirmed, provider: .kick))!
    for segment in playlist.segments.dropFirst() {
      precondition(rolling.segments.first { $0.sequence == segment.sequence }?.lines.last == segment.lines.last,
        "Confirmation preserves the sequence of each prefetched segment")
    }
    for boundary in ["#EXT-X-DISCONTINUITY", "#EXT-X-PREFETCH-DISCONTINUITY"] {
      let discontinuous = complete + boundary + "\n" + pending
      precondition(HLSLowLatency.expand(discontinuous, provider: .kick) == discontinuous)
    }
    let encrypted = complete.replacingOccurrences(of: "#EXTINF:", with: "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:") + pending
    precondition(HLSLowLatency.expand(encrypted, provider: .kick) == encrypted)
    precondition(HLSLowLatency.expand(input + "#EXT-X-ENDLIST\n", provider: .kick) == input + "#EXT-X-ENDLIST\n")
    let invalid = HLSLowLatency.expand(complete + "#EXT-X-PREFETCH:file:///tmp/test.ts\n#EXT-X-PREFETCH:http://example.test/video.ts\n", provider: .kick)
    precondition(TwitchAdPlaylist(invalid)!.segments.count == 2)
    print("Passed provider preferences, Kick prefetch timing, confirmation, deduplication, discontinuity, and encryption regressions")
  }
}
