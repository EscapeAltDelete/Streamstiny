import SwiftUI

// The benchmark hosts the real chat without starting playback or authenticated chat.
enum PlaybackResolver {
  static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}
enum TwitchResolver { static let userAgent = PlaybackResolver.userAgent }

@MainActor enum ChatBenchmarkMetrics {
  static var requests = 0
  static var bytes = 0
}

@main struct ChatBenchmarkApp: App {
  var body: some Scene { WindowGroup { Text("Chat benchmark") } }
}
