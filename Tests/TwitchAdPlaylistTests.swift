import Foundation

@main struct TwitchAdPlaylistTests {
  static var checks = 0
  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message); checks += 1
  }
  static func playlist(_ sequence: Int, count: Int = 4, ads: Bool = false, offset: Double = 0,
    length: Double = 2, prefix: String = "main", map: Bool = false, encrypted: Bool = false) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var text = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:\(sequence)\n"
    if ads { text += "#EXT-X-DATERANGE:ID=\"stitched-ad-1\",CLASS=\"twitch-stitched-ad\",START-DATE=\"\(formatter.string(from: Date(timeIntervalSince1970: 1_760_400_000 + Double(sequence) * 2 + offset)))\"\n" }
    if map { text += "#EXT-X-MAP:URI=\"https://video.ttvnw.net/\(prefix)-init.mp4\"\n" }
    if encrypted { text += "#EXT-X-KEY:METHOD=AES-128,URI=\"https://video.ttvnw.net/key\"\n" }
    for i in sequence..<(sequence + count) {
      let date = Date(timeIntervalSince1970: 1_760_400_000 + Double(i) * 2 + offset)
      text += "#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: date))\n#EXTINF:\(length),\nhttps://video.ttvnw.net/\(prefix)-\(i).ts\n"
    }
    return text
  }
  static func parse(_ text: String) -> TwitchAdPlaylist { TwitchAdPlaylist(text)! }
  static func urls(_ text: String) -> [String] { text.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") } }
  static func main() throws {
    check(TwitchAdPlaylist.adTag("#EXT-X-DATERANGE:CLASS=\"twitch-session\"" ) == false, "Session metadata is not an ad")
    check(TwitchAdPlaylist.adTag("#EXT-X-DATERANGE:CLASS=\"twitch-stream-source\"" ) == false, "Source metadata is not an ad")
    check(TwitchAdPlaylist.adTag("#EXT-X-DATERANGE:ID=\"x\",CLASS=\"twitch-stitched-mid\""), "Attribute order independent detection")
    check(TwitchAdPlaylist.adTag("#EXT-X-CUE-OUT:30"), "Cue detection")
    check(TwitchAdPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8") == nil, "Master is not a media timeline")
    check(TwitchAdPlaylist("invalid") == nil, "Reject malformed input")
    check(TwitchAdPlaylist(playlist(1).replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:1", with: "#EXT-X-MEDIA-SEQUENCE:9223372036854775807")) == nil, "Reject sequence overflow")
    check(TwitchAdPlaylist(playlist(1).replacingOccurrences(of: "#EXTINF:2.0,", with: "#EXTINF:nan,")) == nil, "Reject invalid durations")
    var timeline = TwitchAdTimeline()
    let before = timeline.render(parse(playlist(100)), backup: nil, origin: "unused")
    check(urls(before).count == 4, "All clean segments retained")
    let during = timeline.render(parse(playlist(102, ads: true)), backup: parse(playlist(102, prefix: "backup")), origin: "backup")
    check(urls(during) == ["main-102", "main-103", "backup-104", "backup-105"].map { "https://video.ttvnw.net/\($0).ts" }, "Already exposed sequence IDs never change media")
    check(during.components(separatedBy: "#EXT-X-DISCONTINUITY\n").count == 2, "One switch boundary")
    let repeated = timeline.render(parse(playlist(102, ads: true)), backup: nil, origin: "missing")
    check(urls(repeated) == urls(during), "A failed next probe cannot rewrite previously served segments")
    let after = timeline.render(parse(playlist(104)), backup: nil, origin: "unused")
    check(urls(after).suffix(2).allSatisfy { $0.contains("main-") }, "Restore primary on new clean segments")
    check(after.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"), "Discontinuity sequence excludes visible boundaries")
    let rolled = timeline.render(parse(playlist(108)), backup: nil, origin: "unused")
    check(rolled.contains("#EXT-X-DISCONTINUITY-SEQUENCE:2"), "Rolled-out switch boundaries retained in sequence")
    for (backup, reason) in [(playlist(1, ads: true, prefix: "bad"), "Ad-bearing backup"),
      (playlist(1, map: true), "Different initialization structure"),
      (playlist(1, encrypted: true), "Encrypted replacement")] {
      var fresh = TwitchAdTimeline()
      let result = fresh.render(parse(playlist(1, ads: true)), backup: parse(backup), origin: "bad")
      check(urls(result).allSatisfy { $0.contains("main-") }, reason + " retains continuous primary video")
    }
    var encrypted = TwitchAdTimeline()
    let secure = encrypted.render(parse(playlist(1, ads: true, encrypted: true)), backup: parse(playlist(1, prefix: "backup")), origin: "backup")
    check(secure.contains("METHOD=AES-128") && urls(secure).allSatisfy { $0.contains("main-") }, "Encrypted primary preserved")
    var maps = TwitchAdTimeline()
    let fmp4 = maps.render(parse(playlist(1, ads: true, map: true)), backup: parse(playlist(1, prefix: "backup", map: true)), origin: "backup")
    check(fmp4.contains("backup-init.mp4") && !fmp4.contains("main-init.mp4"), "Backup initialization map follows its media")
    var strict = TwitchAdTimeline()
    let preroll = strict.render(parse(playlist(1, ads: true)), backup: nil, origin: "backup", force: true)
    check(urls(preroll).isEmpty, "Force mode never exposes preroll ad segments")
    check(strict.waiting, "Force-mode preroll exposes a waiting state")
    let strictClean = strict.render(parse(playlist(1)), backup: nil, origin: "backup", force: true)
    let blocked = strict.render(parse(playlist(5, ads: true)), backup: nil, origin: "backup", force: true)
    check(urls(blocked) == urls(strictClean), "Force mode holds known-clean window rather than forwarding ads")
    let strictBackup = strict.render(parse(playlist(5, ads: true)), backup: parse(playlist(5, prefix: "backup")), origin: "backup", force: true)
    check(urls(strictBackup).allSatisfy { $0.contains("backup-") }, "Force mode resumes compatible clean backup")
    let strictReturn = strict.render(parse(playlist(9)), backup: nil, origin: "backup", force: true)
    check(urls(strictReturn).allSatisfy { $0.contains("main-") }, "Force mode resumes clean primary")
    check(!strict.waiting, "Clean primary clears waiting state")
    var partial = TwitchAdTimeline()
    let noHoles = partial.render(parse(playlist(1, ads: true)), backup: parse(playlist(2, prefix: "backup")), origin: "backup", force: true)
    check(urls(noHoles).count == 4 && urls(noHoles).allSatisfy { $0.contains("backup-") }, "Force mode starts the complete backup without requiring the primary first segment")
    // PietSmiet-style preroll: the only clean rendition has independent
    // sequence numbers, clock offset, segment length, resolution and AVC profile.
    var independent = TwitchAdTimeline()
    let alternate = playlist(700, offset: -1397, length: 1, prefix: "mobile")
    let fallback = independent.render(parse(playlist(1, ads: true)), backup: parse(alternate), origin: "mobile", force: true)
    check(urls(fallback).count == 4 && urls(fallback).allSatisfy { $0.contains("mobile-") }, "Independent clean feed replaces preroll")
    check(!independent.waiting, "Low-quality clean feed releases force-mode waiting")
    check(fallback.contains("#EXT-X-MEDIA-SEQUENCE:1"), "Output sequence is independent of backup sequence")
    let advanced = independent.render(parse(playlist(3, ads: true)),
      backup: parse(playlist(702, offset: -1397, length: 1, prefix: "mobile")), origin: "mobile", force: true)
    check(advanced.contains("#EXT-X-MEDIA-SEQUENCE:3"), "Backup polls advance stable output sequence")
    let restored = independent.render(parse(playlist(7)), backup: nil, origin: "mobile", force: true)
    check(urls(restored).suffix(2).allSatisfy { $0.contains("main-") }, "Return to requested quality when primary is clean")
    check(restored.contains("#EXT-X-DISCONTINUITY"), "Whole-feed return has a decoder boundary")
    check(!restored.contains("#EXT-X-PROGRAM-DATE-TIME:"), "Do not advertise conflicting upstream wall clocks")
    var differentDuration = TwitchAdTimeline()
    let longSegments = differentDuration.render(parse(playlist(1, ads: true)),
      backup: parse(playlist(20, length: 6, prefix: "long")), origin: "long", force: true)
    check(longSegments.contains("#EXT-X-TARGETDURATION:6"), "Target duration covers complete backup segments")
    check(urls(longSegments).allSatisfy { $0.contains("long-") }, "Different segment lengths are playable without splicing")
    func variant(_ height: Int, _ codec: String = "avc1.64002A,mp4a.40.2", external: Bool = false) -> HLSVariant {
      HLSVariant(url: URL(string: "https://video.ttvnw.net/\(height).m3u8")!, width: height * 16 / 9,
        height: height, bandwidth: Double(height * 1000), frameRate: 60, externalMedia: external, codecs: codec)
    }
    let source = variant(1080)
    let ranked = TwitchBackupSelection.ranked([variant(360, "avc1.42E01E,mp4a.40.2"),
      variant(720), variant(1080), variant(2160), variant(480, "hvc1.1.6.L120,mp4a.40.2"),
      variant(1080, external: true)], for: source)
    check(ranked.map(\.height) == [1080, 720, 360, 2160], "Prefer requested quality, allow lower AVC profile, exclude separate audio and HEVC")
    var noDates = TwitchAdTimeline()
    func undated(_ text: String) -> String {
      text.components(separatedBy: .newlines).filter { !$0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") }.joined(separator: "\n")
    }
    _ = noDates.render(parse(undated(playlist(1))), backup: nil, origin: "none")
    let noDateSwitch = noDates.render(parse(undated(playlist(3, ads: true))),
      backup: parse(undated(playlist(700, prefix: "mobile"))), origin: "mobile", force: true)
    check(urls(noDateSwitch).suffix(2).allSatisfy { $0.contains("mobile-") }, "Undated feed switches at its live edge")
    let noDateRepeat = noDates.render(parse(undated(playlist(3, ads: true))),
      backup: parse(undated(playlist(700, prefix: "mobile"))), origin: "mobile", force: true)
    check(noDateRepeat == noDateSwitch, "Repeated undated window cannot duplicate media")
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    func captured(_ name: String) throws -> TwitchAdPlaylist {
      parse(try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8))
    }
    let pietsmietLive = try captured("pietsmiet-site-1080.m3u8")
    let pietsmietAd = try captured("pietsmiet-embed-1080.m3u8")
    let pietsmietMobile = try captured("pietsmiet-autoplay-360.m3u8")
    check(!pietsmietLive.hasAds && pietsmietLive.segments.count == 15, "Captured PietSmiet 1080p live feed is not an ad merely because it carries twitch-trigger")
    check(pietsmietAd.hasAds && pietsmietAd.cleanSuffix == nil, "Captured Amazon preroll remains blocked")
    check(!pietsmietMobile.hasAds, "Captured autoplay live feed is usable too")
    for force in [false, true] {
      var capturedTimeline = TwitchAdTimeline()
      let clean = capturedTimeline.render(pietsmietAd, backup: pietsmietLive, origin: "1080p", force: force)
      check(!parse(clean).hasAds && urls(clean).count == 15, "Both modes replace the captured preroll with 1080p live video")
      check(!capturedTimeline.waiting, "Usable 1080p clears the waiting state")
    }
    let labelledAd = playlist(1).replacingOccurrences(of: "#EXTINF:2.0,", with: "#EXTINF:2.0,Amazon|fixture")
    check(parse(labelledAd).hasAds, "Ad-labelled segments are detected even without DATERANGE")
    let trigger = "#EXT-X-DATERANGE:ID=\"trigger\",CLASS=\"twitch-trigger\",START-DATE=\"2026-10-14T00:00:00Z\"\n"
    let triggerLive = playlist(1).replacingOccurrences(of: "#EXTINF:2.0,", with: "#EXTINF:2.0,live")
      .replacingOccurrences(of: "#EXTM3U\n", with: "#EXTM3U\n" + trigger)
    check(!parse(triggerLive).hasAds, "Trigger is only a hint when segments explicitly say live")
    check(parse(playlist(1).replacingOccurrences(of: "#EXTM3U\n", with: "#EXTM3U\n" + trigger)).hasAds, "Trigger with unknown segment identity remains conservative")
    let confirmedLiveTitle = playlist(1, ads: true).replacingOccurrences(of: "#EXTINF:2.0,", with: "#EXTINF:2.0,live")
    check(parse(confirmedLiveTitle).hasAds, "Active stitched-ad range overrides a live title")
    let mixed = labelledAd.replacingOccurrences(of: "#EXTINF:2.0,Amazon|fixture", with: "#EXTINF:2.0,live", range: labelledAd.range(of: "#EXTINF:2.0,Amazon|fixture", options: .backwards))
    let tail = parse(mixed).cleanSuffix!
    check(tail.segments.count == 1 && !tail.hasAds, "Contiguous live tail survives an ad-marked sliding window")
    var tailTimeline = TwitchAdTimeline()
    let tailOutput = tailTimeline.render(parse(mixed), backup: nil, origin: "primary", force: true)
    check(!tailTimeline.waiting && urls(tailOutput).count == 1 && !parse(tailOutput).hasAds, "Force mode resumes on live tail without waiting for old ads to leave the window")
    var skipped = TwitchAdTimeline()
    _ = skipped.render(parse(playlist(1)), backup: nil, origin: "primary")
    let gap = skipped.render(parse(playlist(10)), backup: nil, origin: "primary")
    check(gap.contains("#EXT-X-DISCONTINUITY\n"), "Skipping an expired or ad-only portion creates a decoder boundary")
    var hints = TwitchAdTimeline()
    let speculative = triggerLive + "#EXT-X-TWITCH-PREFETCH:https://fixture.ttvnw.net/adsquared/next.ts\n#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"https://fixture.ttvnw.net/adsquared/part.ts\"\n"
    let completeOnly = hints.render(parse(speculative), backup: nil, origin: "primary", force: true)
    check(!completeOnly.contains("adsquared") && !completeOnly.contains("PREFETCH") && !completeOnly.contains("PRELOAD-HINT"), "Speculative ad media never bypasses complete-segment filtering")
    var longRun = TwitchAdTimeline()
    for sequence in 1...1000 {
      let ads = (sequence / 20) % 2 == 1
      let result = longRun.render(parse(playlist(sequence, ads: ads)), backup: ads ? parse(playlist(sequence, prefix: "backup")) : nil, origin: "backup")
      check(urls(result).count == 4, "Sliding window never loses video segments")
      check(result.contains("#EXT-X-MEDIA-SEQUENCE:\(sequence)"), "Canonical primary sequence preserved")
    }
    let output = CommandLine.arguments.dropFirst().first
    if let output { try fmp4.write(toFile: output, atomically: true, encoding: .utf8) }
    if CommandLine.arguments.count > 2 {
      for (index, directory) in CommandLine.arguments.dropFirst(2).enumerated() {
        let fragmented = index > 0
        var decode = TwitchAdTimeline()
        _ = decode.render(parse(playlist(0, map: fragmented)), backup: nil, origin: "backup")
        _ = decode.render(parse(playlist(0, count: 6, ads: true, map: fragmented)), backup: parse(playlist(0, count: 6, prefix: "backup", map: fragmented)), origin: "backup")
        let rendered = decode.render(parse(playlist(0, count: 8, map: fragmented)), backup: nil, origin: "backup")
          .replacingOccurrences(of: "https://video.ttvnw.net/", with: directory + "/")
          .replacingOccurrences(of: ".ts", with: fragmented ? ".m4s" : ".ts") + "#EXT-X-ENDLIST\n"
        try rendered.write(toFile: directory + "/rendered.m3u8", atomically: true, encoding: .utf8)
      }
    }
    print("Passed \(checks) Twitch playlist checks, including 1,000 sliding-window updates.")
  }
}
