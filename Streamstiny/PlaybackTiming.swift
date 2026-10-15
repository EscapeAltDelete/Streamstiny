import AVFoundation

struct PlaybackTiming {
  let buffered: Double

  init(current: Double, loaded: [CMTimeRange]) {
    guard current.isFinite, current >= 0 else {
      buffered = 0
      return
    }
    let downloaded = Self.intervals(loaded)
    var contiguousEnd = current
    for range in downloaded where range.start <= contiguousEnd + 0.01 {
      if range.end > contiguousEnd { contiguousEnd = range.end }
    }
    buffered = max(0, contiguousEnd - current)
  }

  private static func intervals(_ ranges: [CMTimeRange]) -> [(start: Double, end: Double)] {
    ranges.compactMap { range in
      let start = range.start.seconds
      let end = CMTimeRangeGetEnd(range).seconds
      guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
      return (start: start, end: end)
    }.sorted { $0.start < $1.start }
  }
}
