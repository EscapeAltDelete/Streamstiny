import XCTest
import SwiftUI
import Vision
@testable import ChatBenchmark

@MainActor final class PlayerAcceptanceTests: XCTestCase {
  func testTwitchBitrateAndQualitySwitch() async throws { try await verifyProvider(.twitch, channel: "lirik") }
  func testKickBitrateAndQualitySwitch() async throws { try await verifyProvider(.kick, channel: "westcol") }
  private func verifyProvider(_ provider: StreamSource.Provider, channel: String) async throws {
    let defaults = UserDefaults.standard, previous = UserDefaults.standard.object(forKey: "showBitrate")
    defaults.set(true, forKey: "showBitrate")
    defer { defaults.set(previous, forKey: "showBitrate") }
    let playback = NativePlayback()
    defer { playback.stop() }
    playback.configure(automatic: false, target: 3, highest: false, showBitrate: true)
    let source = StreamSource(provider: provider, key: channel)
    do { _ = try await PlaybackResolver().resolve(source) }
    catch { throw XCTSkip("External \(provider.rawValue) preflight: \(error.localizedDescription)") }
    await playback.load(source)
    if playback.status == .ended { throw XCTSkip("Public \(provider.rawValue) test channel is offline") }
    if let error = playback.error { throw XCTSkip("External \(provider.rawValue) resolver unavailable: \(error)") }
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let host = UIHostingController(rootView: PlaybackSettings(playback: playback, source: source, library: StreamLibrary()))
    window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
    defer { window.rootViewController = UIViewController() }
    for _ in 0..<200 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(playback.bitrate, playback.error ?? "Active representation did not reach the information menu")
    let ids: [String?] = playback.variants.prefix(2).map { Optional($0.id) } + [nil]
    for id in ids {
      playback.chooseQuality(id)
      for _ in 0..<150 {
        if !playback.switching, playback.hls?.engine.isReadyToPlay == true, playback.bitrate != nil { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      XCTAssertEqual(playback.qualityID, id)
      XCTAssertNotNil(playback.bitrate, playback.error ?? "Bitrate missing after quality change")
    }
    let displayed = try text(in: snapshot(host.view, name: "\(provider.rawValue)-bitrate-information"))
    XCTAssertTrue(displayed.localizedCaseInsensitiveContains("advertised"), displayed)
    print("PROVIDER_BITRATE \(provider.rawValue) \(playback.bitrate?.label ?? "unavailable")")
  }
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
    let previousLatency = defaults.object(forKey: "angelthumpLowLatency")
    defaults.set(true, forKey: "angelthumpLowLatency")
    defer { defaults.set(previous, forKey: "showBitrate"); defaults.set(previousLatency, forKey: "angelthumpLowLatency") }
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
    defaults.set(true, forKey: "showBitrate")
    playback.configure(automatic: false, target: 3, highest: false, showBitrate: true)
    for _ in 0..<20 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(playback.bitrate)
    window.rootViewController = UIViewController()
    try await Task.sleep(for: .milliseconds(100))
    let samples = ChatBenchmarkMetrics.bitrateSamples
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(ChatBenchmarkMetrics.bitrateSamples, samples, "Closed menus stop bitrate-specific work")
    XCTAssertNil(playback.bitrate)
    if let quality = playback.variants.first?.id {
      playback.chooseQuality(quality)
      for _ in 0..<100 {
        if !playback.switching, playback.playing { break }
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    let quality = playback.qualityID
    let hls = try XCTUnwrap(playback.hls)
    hls.finish(player: hls.engine, error: nil)
    XCTAssertNotEqual(playback.status, .ended, "A decoder callback is not authoritative stream-end evidence")
    for _ in 0..<100 {
      if !hls.finished, playback.playing { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(playback.hls === hls, "Recover the existing player rather than replacing its ownership")
    XCTAssertFalse(hls.finished, playback.error ?? "Recovery did not reinstall live media")
    XCTAssertTrue(playback.playing, playback.error ?? "Recovered media did not resume")
    XCTAssertEqual(playback.qualityID, quality, "Automatic recovery preserves the selected quality")
    XCTAssertNotEqual(playback.status, .ended)
    let settings = UIHostingController(rootView: SettingsView(chat: ChatStore()))
    window.rootViewController = settings; settings.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    let labels = try text(in: snapshot(settings.view, name: "settings-categories"))
    for category in ["General", "Player", "Chat", "Notifications", "Accounts"] { XCTAssertTrue(labels.contains(category), labels) }
    XCTAssertEqual(defaults.bool(forKey: "showBitrate"), true, "Navigation must not reset preferences")
    window.rootViewController = UIViewController()
  }
}
