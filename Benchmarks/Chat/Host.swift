import SwiftUI

// The benchmark hosts the real chat without starting playback or authenticated chat.
enum PlaybackResolver {
  static let userAgent = "Streamstiny/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
}
enum TwitchResolver { static let userAgent = PlaybackResolver.userAgent }

@MainActor enum ChatBenchmarkMetrics {
  static var requests = 0
  static var bytes = 0
  static var refreshTimes: [Double] = []
}

@main struct ChatBenchmarkApp: App {
  var body: some Scene { WindowGroup { Text("Chat benchmark") } }
}
