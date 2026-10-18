import XCTest
import SwiftUI
import QuartzCore
import MachO
import Observation
import WebKit
@testable import ChatBenchmark

@MainActor final class ChatBenchmarkTests: XCTestCase {
  final class Frames: NSObject {
    var times: [Double] = []
    var link: CADisplayLink?
    func start() {
      link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link?.add(to: .main, forMode: .common)
    }
    @objc func tick(_ link: CADisplayLink) { times.append(link.timestamp) }
    func stop() -> [String: Double] {
      link?.invalidate(); link = nil
      let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.sorted()
      return ["frames": Double(times.count), "p95_frame_ms": gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))],
        "max_frame_ms": gaps.last ?? 0,
        "fps": times.count > 1 ? Double(times.count - 1) / (times.last! - times.first!) : 0]
    }
  }

  @Observable final class Feed {
    var messages: [ChatMessage] = []
  }
  struct Timeline: View {
    let feed: Feed
    let emotes: EmoteStore
    var body: some View {
      ChatList(messages: feed.messages, emotes: emotes, fontSize: 16, timestamps: true,
        onReply: { _ in }, onWhisper: { _ in }, onIgnore: { _ in }, onStream: { _ in })
    }
  }
  func residentBytes() -> Double {
    var info = mach_task_basic_info()
    var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size) }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) : 0
  }
  func findScroll(_ view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView, scroll.isScrollEnabled { return scroll }
    return view.subviews.lazy.compactMap { self.findScroll($0) }.first
  }
  func snapshot(_ window: UIWindow, name: String) {
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    let attachment = XCTAttachment(image: image)
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    try? image.pngData()?.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name + ".png"))
  }
  func testChatPerformance() async throws {
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let emotes = EmoteStore()
    let loadStart = CACurrentMediaTime()
    await emotes.load(force: true)
    XCTAssertGreaterThan(emotes.catalog.count, 300, "Benchmark requires the real current catalog")
    let user = ChatUser(["nick": "Benchmark", "roles": ["PROTECTED"], "subscription": ["tier": 5], "patreonMember": true])
    var results: [String: Any] = ["catalog_count": emotes.catalog.count, "metadata_seconds": CACurrentMediaTime() - loadStart,
      "viewport_width": window.bounds.width, "viewport_height": window.bounds.height,
      "note": "App RSS excludes any WebKit content/network subprocesses; frame intervals use CADisplayLink, not instrumented GPU presentations."]
    for phase in ["cold_picker", "warm_picker", "scroll_picker"] {
      let monitor = Frames(); monitor.start()
      let started = CACurrentMediaTime()
      let controller = UIHostingController(rootView: ChatEmotePicker(emotes: emotes, account: user, insert: { _ in }))
      window.rootViewController = controller
      controller.view.layoutIfNeeded()
      while monitor.times.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
      let first = CACurrentMediaTime() - started
      try await Task.sleep(for: .seconds(2))
      if phase == "scroll_picker", let scroll = findScroll(controller.view) {
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: true)
      }
      try await Task.sleep(for: .seconds(3))
      var metrics = monitor.stop()
      metrics["sample_started_unix"] = Date().timeIntervalSince1970 - 5
      metrics["presentation_to_first_callback_ms"] = first * 1000
      metrics["app_resident_bytes"] = residentBytes()
      metrics["download_calls_cumulative"] = Double(ChatBenchmarkMetrics.requests)
      metrics["download_bytes_cumulative"] = Double(ChatBenchmarkMetrics.bytes)
      for (key, value) in await emotes.benchmarkMetrics() { metrics[key] = value }
      results[phase] = metrics
      snapshot(window, name: phase)
      window.rootViewController = UIHostingController(rootView: Text("Between presentations"))
      try await Task.sleep(for: .milliseconds(250))
    }
    let feed = Feed()
    let words = ["Listening", "pepeW", "PepoPunch", "PEPE", "YEE", "BlueWave"]
    func message(_ index: Int) -> ChatMessage {
      ChatMessage(payload: ["nick": "Benchmark\(index % 20)", "data": "Message \(index) " + words[index % words.count], "timestamp": Double(1700000000000 + index), "features": ["flair127"]])
    }
    feed.messages = (0..<1000).map(message)
    window.rootViewController = UIHostingController(rootView: Timeline(feed: feed, emotes: emotes))
    try await Task.sleep(for: .seconds(2))
    let monitor = Frames(); monitor.start()
    for index in 0..<100 {
      feed.messages = Array((feed.messages + (0..<5).map { message(1000 + index * 5 + $0) }).suffix(1000))
      try await Task.sleep(for: .milliseconds(50))
    }
    var metrics = monitor.stop(); metrics["app_resident_bytes"] = residentBytes()
    results["chat_100_messages_per_second"] = metrics
    snapshot(window, name: "chat-load")
    feed.messages = words.enumerated().map { ChatMessage(payload: ["nick": "Benchmark", "data": $0.element, "timestamp": Double(1700000100000 + $0.offset), "features": ["flair127"]]) }
    for index in 0..<4 { try await Task.sleep(for: .milliseconds(230)); snapshot(window, name: "named-emotes-\(index)") }
    let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    print("CHAT_BENCHMARK " + String(decoding: data, as: UTF8.self))
    try data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.json"))
  }
}
