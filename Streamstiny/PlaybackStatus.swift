import Foundation

enum PlaybackStatus: Equatable {
  case stopped, connecting, buffering, playing, recovering, paused, ended
  case unavailable(String), failed(String)

  var error: String? {
    switch self {
    case .ended: return "This stream has ended."
    case .unavailable(let message), .failed(let message): return message
    default: return nil
    }
  }
  static func retryDelay(attempt: Int) -> Double? {
    guard (0..<3).contains(attempt) else { return nil }
    return pow(2, Double(attempt))
  }
  static func recoverable(_ error: Error) -> Bool {
    if error is CancellationError || error is SourceError || error is TwitchFailure { return false }
    if let error = error as? PlaybackFailure {
      switch error {
      case .offline, .restricted: return false
      case .http(let status): return [403, 404, 408, 429].contains(status) || status >= 500
      case .unavailable: return true
      }
    }
    if let error = error as? URLError {
      return ![.cancelled, .badURL, .unsupportedURL, .userAuthenticationRequired].contains(error.code)
    }
    return true
  }
}

struct StreamBitrate: Equatable, Sendable {
  struct Input: Equatable, Sendable {
    let variants: [HLSVariant]
    let selectedID: String?
    let width: Int
    let height: Int
    let frameRate: Double
    let trackBitrate: Int64
    var value: StreamBitrate? {
      StreamBitrate.advertised(variants: variants, selectedID: selectedID, width: width,
        height: height, frameRate: frameRate, trackBitrate: trackBitrate)
    }
  }
  let bitsPerSecond: Int64
  let average: Bool
  init?(_ bitsPerSecond: Int64, average: Bool = false) {
    guard bitsPerSecond > 0 else { return nil }
    self.bitsPerSecond = bitsPerSecond; self.average = average
  }
  var title: String { average ? "Advertised average bitrate" : "Advertised peak bitrate" }
  var label: String {
    let value = bitsPerSecond >= 1_000_000
      ? String(format: "%.2f Mbps", Double(bitsPerSecond) / 1_000_000)
      : String(format: "%.0f kbps", Double(bitsPerSecond) / 1000)
    return value
  }
  static func advertised(variants: [HLSVariant], selectedID: String?, width: Int, height: Int,
    frameRate: Double, trackBitrate: Int64) -> StreamBitrate? {
    let selected = variants.first { $0.id == selectedID }
    let candidates: [HLSVariant]
    if let selected, !selected.externalMedia { candidates = [selected] }
    else {
      candidates = variants.filter {
        ($0.width == width && $0.height == height && ($0.frameRate == 0 || abs($0.frameRate - frameRate) < 1))
          || ($0.isSource && $0.bandwidth == Double(trackBitrate) && trackBitrate > 0)
      }
    }
    let matched = candidates.filter { $0.bandwidth == Double(trackBitrate) && trackBitrate > 0 }
    guard let variant = matched.count == 1 ? matched.first : candidates.count == 1 ? candidates.first : nil else { return nil }
    return StreamBitrate(Int64(variant.averageBandwidth ?? variant.bandwidth), average: variant.averageBandwidth != nil)
  }
}

struct PlaybackConnectivity {
  private var disconnected = false
  mutating func update(available: Bool) -> Bool {
    let restored = disconnected && available
    disconnected = !available
    return restored
  }
}
