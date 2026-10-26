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
    var visible = true
  }
  struct Timeline: View {
    let feed: Feed
    let emotes: EmoteStore
    var body: some View {
      if feed.visible {
      ChatList(messages: emotes.combining(feed.messages), emotes: emotes, fontSize: 16, timestamps: true,
        onReply: { _ in }, onWhisper: { _ in }, onIgnore: { _ in }, onStream: { _ in }, stateRevision: emotes.revision)
      }
    }
  }
  func refreshMetrics() -> [String: Double] {
    let times = ChatBenchmarkMetrics.refreshTimes.sorted()
    return ["swift_refresh_calls": Double(times.count), "swift_refresh_total_ms": times.reduce(0, +),
      "swift_refresh_median_ms": times.isEmpty ? 0 : times[times.count / 2],
      "swift_refresh_p95_ms": times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count) * 0.95))]]
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
    await emotes.clearBenchmarkCache()
    // In the application the chat surface exists before the picker opens.
    // Keep that context alive for both implementations, without loading emotes.
    let emptyFeed = Feed()
    emptyFeed.messages = (0..<1000).map { ChatMessage(payload: ["nick": "Benchmark", "data": "Existing message \($0)", "timestamp": Double(1700000000000 + $0)]) }
    let background = UIHostingController(rootView: Timeline(feed: emptyFeed, emotes: emotes))
    window.rootViewController = background; window.makeKeyAndVisible(); background.view.layoutIfNeeded()
    let loadStart = CACurrentMediaTime()
    await emotes.load(force: true)
    XCTAssertGreaterThan(emotes.catalog.count, 300, "Benchmark requires the real current catalog")
    guard emotes.catalog.count > 300 else { throw URLError(.cannotLoadFromNetwork) }
    let metadataSeconds = CACurrentMediaTime() - loadStart
    try await Task.sleep(for: .seconds(2))
    let user = ChatUser(["nick": "Benchmark", "roles": ["PROTECTED"], "subscription": ["tier": 5], "patreonMember": true])
    var results: [String: Any] = ["catalog_count": emotes.catalog.count, "metadata_seconds": metadataSeconds,
      "viewport_width": window.bounds.width, "viewport_height": window.bounds.height,
      "note": "App RSS excludes any WebKit content/network subprocesses; frame intervals use CADisplayLink, not instrumented GPU presentations."]
    for phase in ["cold_picker", "warm_picker", "scroll_picker"] {
      ChatBenchmarkMetrics.refreshTimes = []
      let sampleStart = Date().timeIntervalSince1970
      let monitor = Frames(); monitor.start()
      let started = CACurrentMediaTime()
      let controller = UIHostingController(rootView: ChatEmotePicker(emotes: emotes, account: user, insert: { _ in }))
      controller.modalPresentationStyle = .pageSheet
      await withCheckedContinuation { continuation in
        background.present(controller, animated: false) { continuation.resume() }
      }
      controller.view.layoutIfNeeded()
      while monitor.times.isEmpty && CACurrentMediaTime() - started < 3 { try await Task.sleep(for: .milliseconds(5)) }
      XCTAssertFalse(monitor.times.isEmpty, "Display callbacks must be available for a valid measurement")
      let first = CACurrentMediaTime() - started
      if emotes.benchmarkStyles != nil {
        for _ in 0..<250 {
          if findWeb(controller.view) != nil { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(findWeb(controller.view), "A valid WebKit sample requires the picker renderer")
      }
      let web = findWeb(controller.view)
      var readyMilliseconds = first * 1000
      if let web {
        try await startBrowserFrames(web)
        readyMilliseconds = (CACurrentMediaTime() - started) * 1000
      }
      try await Task.sleep(for: .seconds(2))
      if phase == "scroll_picker", let scroll = findScroll(controller.view) {
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: true)
      }
      try await Task.sleep(for: .seconds(3))
      var metrics = monitor.stop()
      metrics["sample_started_unix"] = sampleStart
      metrics["sample_ended_unix"] = Date().timeIntervalSince1970
      metrics["presentation_to_first_callback_ms"] = first * 1000
      metrics["content_ready_ms"] = readyMilliseconds
      metrics["picker_width"] = controller.view.bounds.width
      metrics["picker_height"] = controller.view.bounds.height
      if let web { for (key, value) in try await browserFrames(web) { metrics[key] = value } }
      metrics["app_resident_bytes"] = residentBytes()
      metrics["download_calls_cumulative"] = Double(ChatBenchmarkMetrics.requests)
      metrics["download_bytes_cumulative"] = Double(ChatBenchmarkMetrics.bytes)
      for (key, value) in await emotes.benchmarkMetrics() { metrics[key] = value }
      for (key, value) in refreshMetrics() { metrics[key] = value }
      results[phase] = metrics
      snapshot(window, name: phase)
      background.dismiss(animated: false)
      try await Task.sleep(for: .milliseconds(250))
    }
    let feed = emptyFeed
    let words = ["Listening", "pepeW", "PepoPunch", "PEPE", "YEE", "BlueWave"]
    func message(_ index: Int) -> ChatMessage {
      ChatMessage(payload: ["nick": "Benchmark\(index % 20)", "data": "Message \(index) " + words[index % words.count], "timestamp": Double(1700000000000 + index), "features": ["flair127"]])
    }
    feed.messages = (0..<1000).map(message)
    let timeline = background
    try await Task.sleep(for: .seconds(2))
    let monitor = Frames(); monitor.start()
    let web = findWeb(timeline.view)
    if let web { try await startBrowserFrames(web) }
    ChatBenchmarkMetrics.refreshTimes = []
    let loadStartUnix = Date().timeIntervalSince1970
    for index in 0..<100 {
      feed.messages = Array((feed.messages + (0..<5).map { message(1000 + index * 5 + $0) }).suffix(1000))
      try await Task.sleep(for: .milliseconds(50))
    }
    var metrics = monitor.stop(); metrics["app_resident_bytes"] = residentBytes()
    if let web { for (key, value) in try await browserFrames(web) { metrics[key] = value } }
    metrics["sample_started_unix"] = loadStartUnix
    metrics["sample_ended_unix"] = Date().timeIntervalSince1970
    for (key, value) in refreshMetrics() { metrics[key] = value }
    results["chat_100_messages_per_second"] = metrics
    snapshot(window, name: "chat-load")
    feed.messages = words.enumerated().map { ChatMessage(payload: ["nick": "Benchmark", "data": $0.element, "timestamp": Double(1700000100000 + $0.offset), "features": ["flair127"]]) }
    for index in 0..<4 { try await Task.sleep(for: .milliseconds(230)); snapshot(window, name: "named-emotes-\(index)") }
    func plain(_ index: Int) -> ChatMessage {
      ChatMessage(payload: ["nick": "Benchmark", "data": "Retained plain message \(index)", "timestamp": Double(1700000000000 + index)])
    }
    feed.messages = (0..<5000).map(plain)
    try await Task.sleep(for: .seconds(3))
    let historyStart = Date().timeIntervalSince1970
    let historyFrames = Frames(); historyFrames.start()
    let historyWeb = findWeb(timeline.view)
    if let historyWeb { try await startBrowserFrames(historyWeb) }
    ChatBenchmarkMetrics.refreshTimes = []
    for index in 0..<100 {
      feed.messages = Array((feed.messages + (0..<5).map { plain(5000 + index * 5 + $0) }).suffix(5000))
      try await Task.sleep(for: .milliseconds(50))
    }
    var history = historyFrames.stop()
    for (key, value) in refreshMetrics() { history[key] = value }
    if let historyWeb { for (key, value) in try await browserFrames(historyWeb) { history[key] = value } }
    history["sample_started_unix"] = historyStart
    history["sample_ended_unix"] = Date().timeIntervalSince1970
    history["app_resident_bytes"] = residentBytes()
    results["retained_plain_history"] = history
    if let web = historyWeb {
      let _: Bool = try await javascript(web, "window.scrollTo(0,document.scrollingElement.scrollHeight/2);return true;")
      try await Task.sleep(for: .milliseconds(150))
      try await startBrowserFrames(web)
      let _: Bool = try await javascript(web, """
        window.scrollProbe={writes:0,delays:[]};
        const by=window.scrollBy.bind(window),to=window.scrollTo.bind(window),seen=new WeakSet(),start=Date.now();
        window.scrollBy=(...args)=>{scrollProbe.writes++;by(...args)};
        window.scrollTo=(...args)=>{scrollProbe.writes++;to(...args)};
        const observer=new MutationObserver(entries=>{for(const entry of entries)for(const node of entry.addedNodes){
          if(!node.querySelectorAll)continue;
          for(const time of node.querySelectorAll('[data-unixtimestamp]'))if(!seen.has(time)){
            seen.add(time);const stamp=Number(time.dataset.unixtimestamp);
            if(stamp>=start)scrollProbe.delays.push(Date.now()-stamp);
          }
        }});
        observer.observe(document.getElementById('content'),{childList:true,subtree:true});
        window.userScrolling=true;
        window.dispatchEvent(new PointerEvent('pointerdown'));
        requestAnimationFrame(function move(){if(!userScrolling)return;by(0,-2);requestAnimationFrame(move)});
        window.stopScrollProbe=()=>{observer.disconnect();window.scrollBy=by;window.scrollTo=to};
        return true;
        """)
      let started = Date().timeIntervalSince1970
      let frames = Frames(); frames.start(); ChatBenchmarkMetrics.refreshTimes = []
      for index in 0..<100 {
        feed.messages = Array((feed.messages + (0..<5).map { number in
          ChatMessage(payload: ["uuid": "scroll-\(index)-\(number)", "nick": "Benchmark",
            "data": "Incoming while reading history \(index)-\(number)", "timestamp": Date().timeIntervalSince1970 * 1000])
        }).suffix(5000))
        try await Task.sleep(for: .milliseconds(50))
      }
      var scrolling = frames.stop()
      for (key, value) in refreshMetrics() { scrolling[key] = value }
      for (key, value) in try await browserFrames(web) { scrolling[key] = value }
      let during: Double = try await javascript(web, "window.userScrolling=false;window.dispatchEvent(new PointerEvent('pointerup'));return scrollProbe.writes;")
      try await Task.sleep(for: .milliseconds(200))
      let extra: [String: Double] = try await javascript(web, "const p=scrollProbe,d=p.delays.sort((a,b)=>a-b);stopScrollProbe();return {scroll_writes_during_interaction:during,scroll_writes_after_interaction:p.writes-during,arrival_dom_median_ms:d[Math.floor(d.length/2)]||0,arrival_dom_p95_ms:d[Math.floor(d.length*.95)]||0,observed_messages:d.length};", arguments: ["during": during])
      for (key, value) in extra { scrolling[key] = value }
      scrolling["sample_started_unix"] = started
      scrolling["sample_ended_unix"] = Date().timeIntervalSince1970
      scrolling["app_resident_bytes"] = residentBytes()
      results["scrolling_with_incoming_messages"] = scrolling
    }
    // Model production hiding: remove the renderer while retaining the feed/store.
    feed.visible = false
    try await Task.sleep(for: .seconds(2))
    let hiddenStart = Date().timeIntervalSince1970
    let hiddenFrames = Frames(); hiddenFrames.start()
    for index in 0..<100 {
      feed.messages = Array((feed.messages + (0..<5).map { message(2000 + index * 5 + $0) }).suffix(1000))
      try await Task.sleep(for: .milliseconds(50))
    }
    var hidden = hiddenFrames.stop()
    hidden["sample_started_unix"] = hiddenStart
    hidden["sample_ended_unix"] = Date().timeIntervalSince1970
    hidden["app_resident_bytes"] = residentBytes()
    results["hidden_chat"] = hidden
    let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    print("CHAT_BENCHMARK " + String(decoding: data, as: UTF8.self))
    try data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.json"))
  }
  func startBrowserFrames(_ web: WKWebView) async throws {
    for _ in 0..<250 {
      if (try? await web.evaluateJavaScript("Boolean(window.ChatRenderer && document.getElementById('content').children.length)")) as? Bool == true {
        _ = try await web.evaluateJavaScript("window.benchmarkFrames=[];window.benchmarkRunning=true;requestAnimationFrame(function tick(t){if(!window.benchmarkRunning)return;benchmarkFrames.push(t);requestAnimationFrame(tick)});")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Browser content did not become ready")
    throw URLError(.timedOut)
  }
  func browserFrames(_ web: WKWebView) async throws -> [String: Double] {
    let script = "window.benchmarkRunning=false;const t=window.benchmarkFrames,g=t.slice(1).map((v,i)=>v-t[i]).sort((a,b)=>a-b);return {bottom_distance_px:document.scrollingElement.scrollHeight-document.scrollingElement.clientHeight-document.scrollingElement.scrollTop,browser_frames:t.length,browser_fps:t.length>1?(t.length-1)*1000/(t[t.length-1]-t[0]):0,browser_p95_frame_ms:g[Math.min(g.length-1,Math.floor(g.length*.95))]||0,browser_max_frame_ms:g[g.length-1]||0};"
    return try await javascript(web, script)
  }
}
