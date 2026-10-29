import XCTest
import SwiftUI
import Vision
@testable import ChatBenchmark

@MainActor final class PlayerAcceptanceTests: XCTestCase {
  func testStreamBookmarksPersistWithoutPlayback() throws {
    let suite = "gg.streamstiny.bookmarks." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let custom = try StreamSource.parse("https://example.com/live.m3u8")
    let watched = StreamSource(provider: .youtube, key: "UC554eY5jNUfDq3yDOJYirOQ")
    let library = StreamLibrary(defaults: defaults)
    library.benchmarkConsume(.embeds([DirectoryItem(source: custom, name: "Saved custom", live: true, viewers: 0, dggViewers: 0)]))
    library.select(custom); library.togglePin(custom)
    library.select(watched)
    library.benchmarkConsume(.embeds([]))
    XCTAssertTrue(library.directory.isEmpty)
    XCTAssertEqual(library.pinned.map(\.source), [custom])
    XCTAssertEqual(library.pinned.first?.name, "Saved custom")
    defaults.set(false, forKey: "enableStreamPinning")
    let restarted = StreamLibrary(defaults: defaults)
    XCTAssertFalse(restarted.connected, "Loading bookmarks does not connect discovery or create a player")
    XCTAssertEqual(restarted.pinned, library.pinned)
    XCTAssertEqual(restarted.selected, watched)
    restarted.select(try XCTUnwrap(restarted.pinned.first?.source))
    XCTAssertEqual(restarted.selected, custom)
    XCTAssertEqual(restarted.name(for: custom), "Saved custom")
    XCTAssertEqual(restarted.pinned.count, 1)
    restarted.togglePin(custom)
    XCTAssertTrue(StreamLibrary(defaults: defaults).pinned.isEmpty)
    let duplicate = StreamBookmark(source: custom, name: "Saved custom")
    let invalid = StreamBookmark(source: StreamSource(provider: .direct, key: "http://invalid.test"), name: "Invalid")
    defaults.set(try JSONEncoder().encode([duplicate, duplicate, invalid]), forKey: "pinnedStreams")
    XCTAssertEqual(StreamLibrary(defaults: defaults).pinned, [duplicate], "Ignore invalid and duplicate persisted identities")
    defaults.set(Data("invalid".utf8), forKey: "pinnedStreams")
    XCTAssertTrue(StreamLibrary(defaults: defaults).pinned.isEmpty)
  }

  private func waitForMenu(_ host: UIViewController, presented: Bool) async throws {
    for _ in 0..<200 {
      if presented {
        if let menu = host.presentedViewController, menu.view.window != nil,
          !menu.isBeingPresented, !menu.isBeingDismissed, menu.transitionCoordinator == nil { return }
      } else if host.presentedViewController == nil { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Stream menu transition did not finish")
  }

  func testStreamMenuPinningPresentation() async throws {
    let defaults = UserDefaults.standard, previous = defaults.object(forKey: "enableStreamPinning")
    defaults.set(true, forKey: "enableStreamPinning")
    defer { defaults.set(previous, forKey: "enableStreamPinning") }
    let suite = "gg.streamstiny.menu." + UUID().uuidString
    let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { storage.removePersistentDomain(forName: suite) }
    let library = StreamLibrary(defaults: storage), controls = PlaybackControls()
    defer { controls.cancel() }
    let saved = try StreamSource.parse("https://example.com/live.m3u8")
    library.benchmarkConsume(.embeds([DirectoryItem(source: saved, name: "Saved custom", live: true, viewers: 0, dggViewers: 0)]))
    library.togglePin(saved)
    library.select(StreamSource.initial)
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let host = UIHostingController(rootView: StreamMenu(library: library, controls: controls, addStream: {}))
    window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
    defer { window.rootViewController = UIViewController() }
    controls.menuPresented = true
    try await waitForMenu(host, presented: true)
    let labels = try text(in: snapshot(window, name: "stream-menu-pinned"))
    XCTAssertTrue(labels.localizedCaseInsensitiveContains("Pinned"), labels)
    XCTAssertEqual(labels.components(separatedBy: "Saved custom").count - 1, 1, "Pinned and discovery sections must not duplicate a stream")
    controls.menuPresented = false
    try await waitForMenu(host, presented: false)
    defaults.set(false, forKey: "enableStreamPinning")
    try await Task.sleep(for: .milliseconds(300))
    controls.menuPresented = true
    try await waitForMenu(host, presented: true)
    let disabled = try text(in: snapshot(window, name: "stream-menu-pinning-disabled"))
    XCTAssertFalse(disabled.localizedCaseInsensitiveContains("Pinned"), disabled)
    XCTAssertEqual(library.pinned.count, 1, "Disabling the UI preserves bookmarks")
    library.benchmarkConsume(.embeds([]))
    controls.menuPresented = false
    try await waitForMenu(host, presented: false)
    defaults.set(true, forKey: "enableStreamPinning")
    try await Task.sleep(for: .milliseconds(300))
    controls.menuPresented = true
    try await waitForMenu(host, presented: true)
    let missing = try text(in: snapshot(window, name: "stream-menu-bookmark-after-discovery"))
    XCTAssertTrue(missing.contains("Saved custom"), missing)
    library.select(saved)
    try await Task.sleep(for: .milliseconds(300))
    let selected = try text(in: snapshot(window, name: "stream-menu-selected-bookmark"))
    XCTAssertEqual(selected.components(separatedBy: "Saved custom").count - 1, 1)
    XCTAssertFalse(selected.localizedCaseInsensitiveContains("Pinned"), selected)
  }

  func testTwitchBitrateAndQualitySwitch() async throws { try await verifyProvider(.twitch, channel: "saltybet") }
  func testKickBitrateAndQualitySwitch() async throws { try await verifyProvider(.kick, channel: "xqc") }
  private func verifyProvider(_ provider: StreamSource.Provider, channel: String) async throws {
    let defaults = UserDefaults.standard
    let keys = ["showBitrate", "showViewers", "showDGGViewers"]
    let previous = keys.map { defaults.object(forKey: $0) }
    for key in keys { defaults.set(true, forKey: key) }
    defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
    let suite = "gg.streamstiny.provider." + UUID().uuidString
    let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { storage.removePersistentDomain(forName: suite) }
    let playback = NativePlayback(), controls = PlaybackControls(), library = StreamLibrary(defaults: storage)
    defer { playback.stop(); controls.cancel() }
    playback.configure(automatic: false, target: 3, highest: false, showBitrate: true)
    let source = StreamSource(provider: provider, key: channel)
    do { _ = try await PlaybackResolver().resolve(source) }
    catch { throw XCTSkip("External \(provider.rawValue) preflight: \(error.localizedDescription)") }
    await playback.load(source)
    if playback.status == .ended { throw XCTSkip("Public \(provider.rawValue) test channel is offline") }
    if let error = playback.error { throw XCTSkip("External \(provider.rawValue) resolver unavailable: \(error)") }
    library.select(source)
    library.benchmarkConsume(.embeds([DirectoryItem(source: source, name: channel, live: true, viewers: 1234, dggViewers: 56)]))
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    // This manually hosted controller has no SwiftUI Scene ancestor.
    func player(obscured: Bool = false, phase: ScenePhase = .active) -> some View {
      PlayerView(source: source, doubleTapEnabled: false, playback: playback, controls: controls,
        library: library, statisticsObscured: obscured, addStream: {}, toggleChat: {})
        .environment(\.scenePhase, phase)
    }
    let host = UIHostingController(rootView: player())
    window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
    defer { window.rootViewController = UIViewController() }
    try await Task.sleep(for: .milliseconds(300))
    controls.show(); controls.cancel()
    for _ in 0..<200 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(playback.bitrate, playback.error ?? "Missing UI metric; engine=\(playback.hls?.engine.dynamicInfo?.videoBitrate ?? 0), controls=\(controls.visible), app=\(UIApplication.shared.applicationState.rawValue)")
    var measurements = Set<Int64>()
    for _ in 0..<6 {
      if let value = playback.bitrate { measurements.insert(value.bitsPerSecond) }
      try await Task.sleep(for: .seconds(1))
    }
    print("DYNAMIC_VIDEO_BITRATE \(provider.rawValue) " + measurements.sorted().map(String.init).joined(separator: ","))
    let displayed = try statisticsText(in: host.view, name: "\(provider.rawValue)-original-statistics")
    XCTAssertTrue(displayed.localizedCaseInsensitiveContains("kbps"), displayed)
    XCTAssertFalse(displayed.localizedCaseInsensitiveContains("Mbps"), displayed)
    XCTAssertTrue(displayed.contains("DGG"), displayed)
    XCTAssertTrue(displayed.contains("56"), displayed)
    XCTAssertTrue(displayed.contains("1,234") || displayed.contains("1234"), displayed)
    let ids: [String?] = playback.variants.prefix(2).map { Optional($0.id) } + [nil]
    for id in ids {
      playback.chooseQuality(id)
      for _ in 0..<200 {
        if !playback.switching, playback.hls?.engine.isReadyToPlay == true, playback.bitrate != nil { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      XCTAssertEqual(playback.qualityID, id)
      XCTAssertNotNil(playback.bitrate, playback.error ?? "Bitrate missing after quality change")
    }
    let engine = playback.hls
    library.togglePin(try StreamSource.parse("https://example.com/live.m3u8"))
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(playback.hls === engine, "Bookmarking preserves the existing player")
    XCTAssertEqual(library.selected, source)
    host.rootView = player(obscured: true)
    try await Task.sleep(for: .milliseconds(300))
    let coveredSamples = ChatBenchmarkMetrics.bitrateSamples
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(ChatBenchmarkMetrics.bitrateSamples, coveredSamples, "Application sheets suspend the statistics reader")
    XCTAssertNil(playback.bitrate)
    XCTAssertTrue(playback.hls === engine)
    host.rootView = player()
    for _ in 0..<100 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(playback.bitrate)
    host.rootView = player(phase: .background)
    try await Task.sleep(for: .milliseconds(300))
    let backgroundSamples = ChatBenchmarkMetrics.bitrateSamples
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(ChatBenchmarkMetrics.bitrateSamples, backgroundSamples, "Background scenes suspend statistics")
    XCTAssertNil(playback.bitrate)
    host.rootView = player()
    try await Task.sleep(for: .milliseconds(300))
    controls.show(); controls.cancel()
    for _ in 0..<100 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(playback.bitrate)
    controls.menuPresented = true
    try await Task.sleep(for: .milliseconds(300))
    let samples = ChatBenchmarkMetrics.bitrateSamples
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(ChatBenchmarkMetrics.bitrateSamples, samples, "Obscured statistics do no metric work")
    XCTAssertNil(playback.bitrate)
    controls.menuPresented = false; controls.show(); controls.cancel()
    for _ in 0..<100 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(playback.bitrate)
    defaults.set(false, forKey: "showBitrate")
    try await Task.sleep(for: .milliseconds(300))
    let disabledSamples = ChatBenchmarkMetrics.bitrateSamples
    try await Task.sleep(for: .seconds(2))
    XCTAssertNil(playback.bitrate)
    XCTAssertEqual(ChatBenchmarkMetrics.bitrateSamples, disabledSamples, "Disabled bitrate does no metric work")
    let disabled = try statisticsText(in: host.view, name: "\(provider.rawValue)-statistics-disabled")
    XCTAssertFalse(disabled.localizedCaseInsensitiveContains("kbps"), disabled)
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
  private func statisticsText(in view: UIView, name: String) throws -> String {
    // Inspect the original header, excluding unrelated text inside the live video.
    try text(in: snapshot(view, name: name), region: CGRect(x: 0, y: 0.75, width: 1, height: 0.25))
  }
  private func text(in image: UIImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> String {
    let request = VNRecognizeTextRequest()
    request.minimumTextHeight = 0.005
    request.regionOfInterest = region
    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
    return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
  }
  func testAngelThumpStatisticsAndRecovery() async throws {
    let defaults = UserDefaults.standard, previous = UserDefaults.standard.object(forKey: "showBitrate")
    let previousLatency = defaults.object(forKey: "angelthumpLowLatency")
    defaults.set(true, forKey: "angelthumpLowLatency")
    defer { defaults.set(previous, forKey: "showBitrate"); defaults.set(previousLatency, forKey: "angelthumpLowLatency") }
    defaults.set(true, forKey: "showBitrate")
    let playback = NativePlayback()
    defer { playback.stop() }
    playback.configure(automatic: false, target: 3, highest: false, showBitrate: true)
    let source = StreamSource(provider: .angelthump, key: "beetlorddwight")
    await playback.load(source)
    if playback.status == .ended { throw XCTSkip("Public live test channel is offline") }
    for _ in 0..<150 {
      if playback.hls?.engine.isReadyToPlay == true, !playback.variants.isEmpty { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertTrue(playback.hls?.engine.isReadyToPlay == true, playback.error ?? "No ready player")
    XCTAssertNil(playback.bitrate, "A closed menu performs no bitrate-specific updates")
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let controls = PlaybackControls()
    let host = UIHostingController(rootView: PlayerView(source: source, doubleTapEnabled: false,
      playback: playback, controls: controls, library: StreamLibrary(), addStream: {}, toggleChat: {}).environment(\.scenePhase, .active))
    window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    controls.show(); controls.cancel()
    defer { controls.cancel() }
    for _ in 0..<100 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let bitrate = try XCTUnwrap(playback.bitrate, "The real decoder and playlist must populate the information row")
    try await Task.sleep(for: .milliseconds(300))
    let displayed = try statisticsText(in: host.view, name: "live-bitrate-information")
    XCTAssertTrue(displayed.localizedCaseInsensitiveContains("kbps"), displayed)
    print("PLAYER_BITRATE " + bitrate.title + " " + bitrate.label + " resolution=" + playback.resolution)
    defaults.set(false, forKey: "showBitrate")
    playback.configure(automatic: false, target: 3, highest: false, showBitrate: false)
    try await Task.sleep(for: .milliseconds(300))
    let disabled = try statisticsText(in: host.view, name: "bitrate-disabled")
    XCTAssertFalse(disabled.localizedCaseInsensitiveContains("kbps"), disabled)
    XCTAssertNil(playback.bitrate)
    defaults.set(true, forKey: "showBitrate")
    playback.configure(automatic: false, target: 3, highest: false, showBitrate: true)
    for _ in 0..<20 {
      if playback.bitrate != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(playback.bitrate)
    controls.tap(count: 1, toggleChat: {})
    controls.cancel()
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
