import Foundation

// Compile against production sources; keep the workload identical for both refs.
@main struct RuntimeBenchmarks {
  static func main() throws {
    var checksum = 0
    var results: [String: Any] = [:]
    func measure(_ name: String, count: Int, _ operation: () -> Int) {
      let clock = ContinuousClock()
      let cold = clock.measure { checksum &+= operation() }
      for _ in 0..<20 { checksum &+= operation() }
      var samples: [Double] = []
      for _ in 0..<5 {
        let elapsed = clock.measure { for _ in 0..<count { checksum &+= operation() } }
        let value = elapsed.components
        samples.append(Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15)
      }
      let value = cold.components
      results[name] = ["iterations": count, "cold_ms": Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15,
        "warm_median_ms": samples.sorted()[samples.count / 2], "warm_samples_ms": samples]
    }
    let plain = "An ordinary chat message with unicode café 👋🏽 and no markup"
    let markup = "<script x='🙃'>& \"Listening\" café 👋🏽</script>"
    measure("escape_plain", count: 100_000) { ChatHTML.escape(plain).utf8.count }
    measure("escape_markup", count: 100_000) { ChatHTML.escape(markup).utf8.count }
    let url = URL(string: "https://r2cdn.destiny.gg/emotes/example.png")!
    measure("message_markup", count: 10_000) {
      ChatHTML.body("Hello Listening café 👋🏽 https://example.com/path?q=1&x=2 #twitch/channel <test>", emote: { $0 == "Listening" ? url : nil }).utf8.count
    }
    for ranges in [0, 4, 16] {
      var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:10"]
      for index in 0..<ranges {
        lines.append("#EXT-X-DATERANGE:ID=\"stitched-ad-\(index)\",CLASS=\"twitch-stitched-ad\",START-DATE=\"2026-10-18T00:00:00.000Z\",END-DATE=\"2026-10-18T00:00:00.250Z\"")
      }
      for index in 0..<40 {
        lines += [String(format: "#EXT-X-PROGRAM-DATE-TIME:2026-10-18T00:00:%02d.000Z", index), "#EXTINF:1.0,live", "segment\(index).ts"]
      }
      let playlist = lines.joined(separator: "\n") + "\n"
      measure("twitch_playlist_\(ranges)_ranges", count: 100) {
        guard let parsed = TwitchAdPlaylist(playlist) else { preconditionFailure("Invalid benchmark fixture") }
        return parsed.segments.count + parsed.segments.filter(\.isAd).count
      }
    }
    let data = try JSONSerialization.data(withJSONObject: ["measurements": results, "checksum": checksum], options: [.sortedKeys])
    print("RUNTIME_BENCHMARK " + String(decoding: data, as: UTF8.self))
  }
}
