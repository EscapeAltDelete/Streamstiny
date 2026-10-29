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
  let bitsPerSecond: Int64
  init?(_ bitsPerSecond: Int64) {
    guard bitsPerSecond > 0 else { return nil }
    self.bitsPerSecond = bitsPerSecond
  }
  var title: String { "Estimated video bitrate" }
  var label: String { String(format: "%.0f kbps", Double(bitsPerSecond) / 1000) }
}

struct PlaybackConnectivity {
  private var disconnected = false
  mutating func update(available: Bool) -> Bool {
    let restored = disconnected && available
    disconnected = !available
    return restored
  }
}
