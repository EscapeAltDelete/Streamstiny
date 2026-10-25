import XCTest
import SwiftUI
import Vision
@testable import ChatBenchmark

@MainActor final class PlayerAcceptanceTests: XCTestCase {
  private func snapshot(_ view: UIView, name: String) -> UIImage {
    view.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    return image
  }
  private func text(in image: UIImage) throws -> String {
    let request = VNRecognizeTextRequest()
    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
    return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
  }
  func testLiveBitrateAppearsOnlyInInformation() async throws {
    let defaults = UserDefaults.standard, previous = UserDefaults.standard.object(forKey: "showBitrate")
    defer { defaults.set(previous, forKey: "showBitrate") }
    defaults.set(true, forKey: "showBitrate")
    let playback = NativePlayback()
    defer { playback.stop() }
    playback.configure(automatic: false, target: 3, highest: false, showBitrate: true)
    let source = StreamSource(provider: .angelthump, key: "yodime")
    await playback.load(source)
    if playback.status == .ended { throw XCTSkip("Public live test channel is offline") }
    for _ in 0..<150 {
      if playback.hls?.engine.isReadyToPlay == true, !playback.variants.isEmpty { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertTrue(playback.hls?.engine.isReadyToPlay == true, playback.error ?? "No ready player")
    XCTAssertNil(playback.bitrate, "A closed menu performs no bitrate-specific updates")
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let host = UIHostingController(rootView: PlaybackSettings(playback: playback, source: source, library: StreamLibrary()))
    window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
    for _ in 0..<30 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let bitrate = try XCTUnwrap(playback.bitrate, "The real decoder and playlist must populate the information row")
    try await Task.sleep(for: .milliseconds(300))
    let displayed = try text(in: snapshot(host.view, name: "live-bitrate-information"))
    XCTAssertTrue(displayed.localizedCaseInsensitiveContains("advertised"), displayed)
    XCTAssertTrue(displayed.contains("Mbps") || displayed.contains("kbps"), displayed)
    print("PLAYER_BITRATE " + bitrate.title + " " + bitrate.label + " resolution=" + playback.resolution)
    defaults.set(false, forKey: "showBitrate")
    playback.configure(automatic: false, target: 3, highest: false, showBitrate: false)
    try await Task.sleep(for: .milliseconds(300))
    let disabled = try text(in: snapshot(host.view, name: "bitrate-disabled"))
    XCTAssertFalse(disabled.localizedCaseInsensitiveContains("advertised"), disabled)
    XCTAssertNil(playback.bitrate)
    window.rootViewController = UIViewController()
    try await Task.sleep(for: .milliseconds(100))
    let samples = ChatBenchmarkMetrics.bitrateSamples
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(ChatBenchmarkMetrics.bitrateSamples, samples, "Closed menus stop bitrate-specific work")
    let settings = UIHostingController(rootView: SettingsView(chat: ChatStore()))
    window.rootViewController = settings; settings.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    let labels = try text(in: snapshot(settings.view, name: "settings-categories"))
    for category in ["General", "Player", "Chat", "Notifications", "Accounts"] { XCTAssertTrue(labels.contains(category), labels) }
    XCTAssertEqual(defaults.bool(forKey: "showBitrate"), false, "Navigation must not reset preferences")
    window.rootViewController = UIViewController()
  }
}
