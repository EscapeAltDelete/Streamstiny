import Foundation

// Parse complete media segments; encrypted feeds are never mixed.
struct TwitchAdPlaylist: Sendable {
  struct Segment: Sendable {
    let sequence: Int64
    let start: Date?
    let duration: Double
    let lines: [String]
    let map: String?
    let encrypted: Bool
    let isAd: Bool
  }
  let header: [String]
  let segments: [Segment]
  let trailer: [String]
  let hasAds: Bool
  static func adTag(_ line: String) -> Bool {
    if line.hasPrefix("#EXT-X-CUE-OUT") { return true }
    guard line.hasPrefix("#EXT-X-DATERANGE:") else { return false }
    let fields = HLSPlaylist.attributes(line)
    let name = fields["CLASS"] ?? ""
    return name.hasPrefix("twitch-stitched") || name == "twitch-maf-ad" || name == "twitch-trigger"
      || (fields["ID"]?.hasPrefix("stitched-ad") == true)
  }
  init?(_ text: String) {
    guard text.hasPrefix("#EXTM3U"), !text.contains("#EXT-X-STREAM-INF:") else { return nil }
    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard let sequenceLine = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }),
      let sequence = Int64(sequenceLine.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)),
      sequence >= 0, sequence <= Int64.max - 1000 else { return nil }
    let dates = ISO8601DateFormatter()
    dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let seconds = ISO8601DateFormatter()
    var header: [String] = [], pending: [String] = [], segments: [Segment] = []
    var date: Date?, duration: Double?, map: String?, encrypted = false, started = false
    var cueOut = false, title = ""
    for line in lines {
      if line.hasPrefix("#EXT-X-CUE-OUT") { cueOut = true }
      if line.hasPrefix("#EXT-X-CUE-IN") { cueOut = false }
      if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
        let value = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
        guard let parsed = dates.date(from: value) ?? seconds.date(from: value) else { return nil }
        date = parsed; started = true; pending.append(line)
      } else if line.hasPrefix("#EXTINF:") {
        guard let value = Double(line.dropFirst(8).split(separator: ",").first ?? ""), value > 0, value <= 120 else { return nil }
        duration = value
        title = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        started = true; pending.append(line)
      } else if line.hasPrefix("#EXT-X-MAP:") {
        map = line
      } else if line.hasPrefix("#EXT-X-KEY:") {
        // Encrypted playlists pass through unchanged; keys are never mixed across feeds.
        encrypted = HLSPlaylist.attributes(line)["METHOD"] != "NONE"
        pending.append(line); started = true
      } else if !line.hasPrefix("#") {
        guard let length = duration, segments.count < 1000 else { return nil }
        segments.append(Segment(sequence: sequence + Int64(segments.count), start: date,
          duration: length, lines: pending + [line], map: map, encrypted: encrypted,
          isAd: cueOut || line.contains("/adsquared/") || (!title.isEmpty && title != "live")))
        date = date?.addingTimeInterval(length); duration = nil; pending = []
      } else if started { pending.append(line) } else { header.append(line) }
    }
    guard !segments.isEmpty else { return nil }
    // Parse each advertised interval once, not once for every segment.
    let ranges = lines.filter { $0.hasPrefix("#EXT-X-DATERANGE:") && Self.adTag($0) }
      .map { line -> (trigger: Bool, start: Date?, end: Date?) in
        let fields = HLSPlaylist.attributes(line)
        if fields["CLASS"] == "twitch-trigger" { return (true, nil, nil) }
        let start = fields["START-DATE"].flatMap { dates.date(from: $0) ?? seconds.date(from: $0) }
        let end = fields["END-DATE"].flatMap { dates.date(from: $0) ?? seconds.date(from: $0) }
          ?? fields["DURATION"].flatMap(Double.init).flatMap { duration in
            duration.isFinite && duration >= 0 ? start?.addingTimeInterval(duration) : nil
          }
        return (false, start, end)
      }
    self.segments = ranges.isEmpty ? segments : segments.map { segment in
      let rangedAd = ranges.contains { range in
        // PietSmiet emits this client-side trigger on ordinary live media.
        // It is not evidence of an inserted ad when EXTINF explicitly says live.
        if range.trigger {
          return !segment.lines.contains { $0.hasPrefix("#EXTINF:") && $0.hasSuffix(",live") }
        }
        guard let start = segment.start, let adStart = range.start else { return true }
        if let end = range.end { return start < end && start.addingTimeInterval(segment.duration) > adStart }
        return start.addingTimeInterval(segment.duration) > adStart
      }
      return Segment(sequence: segment.sequence, start: segment.start, duration: segment.duration,
        lines: segment.lines, map: segment.map, encrypted: segment.encrypted, isAd: segment.isAd || rangedAd)
    }
    self.header = header; trailer = pending
    hasAds = self.segments.contains(where: { $0.isAd })
  }
  // Only take the contiguous live tail, never splice around an ad in the middle.
  var cleanSuffix: TwitchAdPlaylist? {
    guard let lastAd = segments.lastIndex(where: { $0.isAd }) else { return self }
    let tail = Array(segments.dropFirst(lastAd + 1))
    guard !tail.isEmpty else { return nil }
    return TwitchAdPlaylist(header: header, segments: tail, trailer: trailer, hasAds: false)
  }
  private init(header: [String], segments: [Segment], trailer: [String], hasAds: Bool) {
    self.header = header; self.segments = segments; self.trailer = trailer; self.hasAds = hasAds
  }
}

// Output sequence numbers belong to this session, not to either upstream feed.
// A rendition switch appends complete segments at a discontinuity. Never replace
// media already advertised under an output sequence number.
struct TwitchAdTimeline {
  private struct Entry {
    let sequence: Int64
    let segment: TwitchAdPlaylist.Segment
    let discontinuitiesBefore: Int
    let boundary: Bool
  }
  private var entries: [Entry] = []
  private var nextSequence: Int64?
  private var currentOrigin: String?
  private var upstreamSequence: Int64 = -1
  private var lastEnd: Date?
  private var discontinuities = 0
  private var targetDuration = 1
  private var lastOutput: String?
  private(set) var waiting = false

  mutating func render(_ primary: TwitchAdPlaylist, backup: TwitchAdPlaylist?, origin: String, force: Bool = false) -> String {
    let cleanBackup = backup?.cleanSuffix.flatMap { playlist -> TwitchAdPlaylist? in
      guard !playlist.segments.contains(where: { $0.encrypted }),
        !primary.segments.contains(where: { $0.encrypted }),
        (playlist.segments.first?.map == nil) == (primary.segments.first?.map == nil)
      else { return nil }
      return playlist
    }
    let cleanPrimary = primary.cleanSuffix
    waiting = force && primary.hasAds && cleanBackup == nil && cleanPrimary == nil
    if waiting {
      return lastOutput ?? "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
    }
    let selected = primary.hasAds ? cleanBackup ?? cleanPrimary ?? primary : primary
    let selectedOrigin = primary.hasAds && cleanBackup != nil ? origin : "primary"
    let switching = currentOrigin != nil && currentOrigin != selectedOrigin
    let reset = currentOrigin == selectedOrigin && selected.segments.last!.sequence < upstreamSequence
    let boundary = switching || reset
    if nextSequence == nil {
      nextSequence = primary.segments.first!.sequence
      discontinuities = selected.header.first { $0.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") }
        .flatMap { Int($0.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count)) } ?? 0
    }
    var additions = selected.segments.filter { segment in
      if currentOrigin == nil { return true }
      if !boundary { return segment.sequence > upstreamSequence }
      // Clocks need not align exactly. Skip already-played content, accepting
      // a small gap at the switch rather than splicing unrelated segment bytes.
      if let end = lastEnd, let start = segment.start { return start >= end.addingTimeInterval(-0.05) }
      return true
    }
    if boundary && (lastEnd == nil || additions.contains(where: { $0.start == nil })) {
      additions = Array(additions.suffix(2))
    }
    for (index, segment) in additions.enumerated() {
      let skippedMedia = currentOrigin == selectedOrigin && segment.sequence > upstreamSequence + 1
      let switchBoundary = (boundary && index == 0) || skippedMedia
      let embedded = segment.lines.filter { $0 == "#EXT-X-DISCONTINUITY" }.count
      entries.append(Entry(sequence: nextSequence!, segment: segment,
        discontinuitiesBefore: discontinuities, boundary: switchBoundary))
      discontinuities += embedded + (switchBoundary ? 1 : 0)
      nextSequence! += 1
      lastEnd = segment.start?.addingTimeInterval(segment.duration)
      upstreamSequence = segment.sequence
      currentOrigin = selectedOrigin
      targetDuration = max(targetDuration, Int(ceil(segment.duration)))
    }
    // A stale backup must not replace the last usable manifest with an empty one.
    if additions.isEmpty, let lastOutput { return lastOutput }
    let window = max(3, selected.segments.count)
    if entries.count > window { entries.removeFirst(entries.count - window) }
    guard let first = entries.first else { return lastOutput ?? "#EXTM3U\n" }
    var lines = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-TARGETDURATION:\(targetDuration)",
      "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)",
      "#EXT-X-DISCONTINUITY-SEQUENCE:\(first.discontinuitiesBefore)"]
    for entry in entries {
      if entry.boundary { lines.append("#EXT-X-DISCONTINUITY") }
      if let map = entry.segment.map { lines.append(map) }
      lines += entry.segment.lines.filter {
        !TwitchAdPlaylist.adTag($0) && !$0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
          && !$0.hasPrefix("#EXT-X-PART:") && !$0.hasPrefix("#EXT-X-PRELOAD-HINT:")
          && !$0.hasPrefix("#EXT-X-TWITCH-PREFETCH:")
      }
    }
    // This gateway serves complete segments only, never speculative media hints.
    lines += selected.trailer.filter { $0 == "#EXT-X-ENDLIST" }
    let output = lines.joined(separator: "\n") + "\n"
    lastOutput = output
    return output
  }
}

// Resolution and H.264 profile differences do not require matching segment clocks.
// Keep codec families and container formats compatible with the active decoder.
enum TwitchBackupSelection {
  private static func families(_ codecs: String) -> Set<String> {
    Set(codecs.lowercased().split(separator: ",").map {
      let codec = $0.trimmingCharacters(in: .whitespaces)
      if codec.hasPrefix("avc") || codec == "h264" { return "h264" }
      if codec.hasPrefix("hvc") || codec.hasPrefix("hev") || codec == "h265" { return "h265" }
      return String(codec.split(separator: ".").first ?? "")
    })
  }
  static func compatible(_ candidate: HLSVariant, with primary: HLSVariant) -> Bool {
    !candidate.externalMedia && candidate.height > 0
      && families(candidate.codecs) == families(primary.codecs)
  }
  static func ranked(_ candidates: [HLSVariant], for primary: HLSVariant) -> [HLSVariant] {
    candidates.filter { compatible($0, with: primary) }.sorted {
      let leftFits = $0.height <= primary.height, rightFits = $1.height <= primary.height
      if leftFits != rightFits { return leftFits }
      if $0.height != $1.height { return $0.height > $1.height }
      return $0.frameRate > $1.frameRate
    }
  }
}

// Twitch advertises open, chunked media under its own prefetch tag.
// Present it as the next segment so FFmpeg can read it while it is produced.
enum TwitchLowLatency {
  static func expand(_ text: String) -> String {
    guard !text.contains("#EXT-X-ENDLIST"), let playlist = TwitchAdPlaylist(text),
      !playlist.hasAds, !playlist.segments.contains(where: { $0.encrypted }) else { return text }
    let duration = playlist.segments.map(\.duration).reduce(0, +) / Double(playlist.segments.count)
    var lines: [String] = []
    var discontinuity = false
    for line in text.components(separatedBy: .newlines) {
      if line == "#EXT-X-DISCONTINUITY" || line == "#EXT-X-TWITCH-PREFETCH-DISCONTINUITY" { discontinuity = true }
      if !line.isEmpty, !line.hasPrefix("#") { discontinuity = false }
      if line.hasPrefix("#EXT-X-TWITCH-PREFETCH:"), !discontinuity {
        let address = String(line.dropFirst("#EXT-X-TWITCH-PREFETCH:".count))
        guard let url = URL(string: address), url.scheme == nil || url.scheme == "https",
          !address.isEmpty else { continue }
        lines += ["#EXTINF:\(duration),live", address]
      } else { lines.append(line) }
    }
    return lines.joined(separator: "\n")
  }
}
