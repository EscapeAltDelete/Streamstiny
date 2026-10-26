import XCTest
import SwiftUI
import WebKit
import CryptoKit
import ImageIO
@testable import ChatBenchmark

@MainActor extension ChatBenchmarkTests {
  func javascript<T>(_ web: WKWebView, _ body: String, arguments: [String: Any] = [:]) async throws -> T {
    let result: Any = try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { continuation.resume(with: $0) }
    }
    return try XCTUnwrap(result as? T, "Unexpected JavaScript result: \(result)")
  }
  func findWeb(_ view: UIView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    return view.subviews.lazy.compactMap { self.findWeb($0) }.first
  }
  func waitForRenderer(_ web: WKWebView) async throws {
    for _ in 0..<200 {
      if (try? await web.evaluateJavaScript("Boolean(window.ChatRenderer && document.querySelector('.msg-chat'))")) as? Bool == true { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Chat renderer never produced message content")
    throw URLError(.timedOut)
  }
  func testMessageActionsAndPruning() async throws {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: "removedChatMessages")
    defaults.set(1, forKey: "removedChatMessages")
    defer { defaults.set(previous, forKey: "removedChatMessages") }
    let emotes = EmoteStore()
    let chat = ChatStore()
    var removed = ChatMessage(payload: ["uuid": "removed-row", "nick": "Benchmark", "data": "Deleted text"])
    removed.removed = true
    let other = ChatMessage(payload: ["uuid": "stable-row", "nick": "Benchmark", "data": "Unchanged text"])
    func list(_ messages: [ChatMessage]) -> ChatList {
      ChatList(messages: messages, emotes: emotes, fontSize: 16, timestamps: false,
        onReply: { _ in }, onWhisper: { _ in }, onIgnore: { _ in }, onStream: { _ in }, chat: chat)
    }
    let coordinator = list([removed, other]).makeCoordinator()
    let web = coordinator.makeWebView()
    defer { coordinator.stop(); web.removeFromSuperview() }
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(web); web.frame = window.bounds
    web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.view.layoutIfNeeded()
    try await waitForRenderer(web)
    var initial = false
    for _ in 0..<100 {
      initial = try await javascript(web, "const row=document.querySelector('[data-message=removed-row]');return Boolean(row?.textContent.includes('message deleted')) && !row.textContent.includes('Deleted text');")
      if initial { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let initialState: String = try await javascript(web, "window.stableRow=document.querySelector('[data-message=stable-row]');return JSON.stringify({text:document.querySelector('[data-message=removed-row]')?.textContent,width:innerWidth,height:innerHeight,metrics:ChatRenderer.metrics()});")
    XCTAssertTrue(initial, initialState)
    for expected in [true, false] {
      let action = try XCTUnwrap(coordinator.actions(["id": removed.id]).first as? UIAction)
      let button = UIButton(type: .system, primaryAction: action)
      button.sendActions(for: .primaryActionTriggered)
      var matches = false
      for _ in 0..<100 {
        matches = try await javascript(web, "return document.body.textContent.includes('Deleted text')===expected;", arguments: ["expected": expected])
        if matches { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertTrue(matches, "Reveal/hide must invalidate rendering without losing message actions")
      let stable: Bool = try await javascript(web, "return stableRow===document.querySelector('[data-message=stable-row]');")
      XCTAssertTrue(stable)
      XCTAssertFalse(coordinator.actions(["id": removed.id]).isEmpty)
    }
    let oldTags = defaults.object(forKey: "chatTags"), oldColors = defaults.object(forKey: "chatTagColors")
    defer { defaults.set(oldTags, forKey: "chatTags"); defaults.set(oldColors, forKey: "chatTagColors") }
    chat.tag("Benchmark", text: "Cache invalidation")
    coordinator.refresh()
    var tagged = false
    for _ in 0..<100 {
      tagged = try await javascript(web, "return document.querySelector('[data-message=stable-row] .tag')?.textContent==='[Cache invalidation]';")
      if tagged { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(tagged, "Tag changes must invalidate unchanged messages even with the default revision argument")
    let oldWords = defaults.object(forKey: "censoredChatWords"), oldCensor = defaults.object(forKey: "censorChatWords")
    defer { defaults.set(oldWords, forKey: "censoredChatWords"); defaults.set(oldCensor, forKey: "censorChatWords") }
    defaults.set("Unchanged", forKey: "censoredChatWords"); defaults.set(true, forKey: "censorChatWords")
    coordinator.refresh()
    var censored = false
    for _ in 0..<100 {
      censored = try await javascript(web, "return document.querySelector('[data-message=stable-row] .text')?.textContent==='••••••••• text';")
      if censored { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(censored, "Text-rule changes must invalidate unchanged messages")
    coordinator.parent = list([]); coordinator.refresh()
    for _ in 0..<100 {
      let count: Int = try await javascript(web, "return document.querySelectorAll('[data-message]').length;")
      if count == 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(coordinator.actions(["id": removed.id]).isEmpty, "Pruning releases the canonical message state")
  }
  func testNativeEmoteRendering() async throws {
    let emotes = EmoteStore()
    await emotes.load(force: true)
    guard let styles = emotes.benchmarkStyles else { throw XCTSkip("Legacy UIKit decoder: known format failures recorded by baseline screenshots") }
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let names = ["Listening", "pepeW", "PepoPunch"]
    let feed = Feed()
    feed.messages = names.enumerated().map { index, name in
      ChatMessage(payload: ["nick": "Benchmark", "data": name, "timestamp": Double(1700000000000 + index),
        "features": ["flair127", "flair18", "flair13"], "roles": ["PROTECTED"]])
    }
    let controller = UIHostingController(rootView: Timeline(feed: feed, emotes: emotes))
    window.rootViewController = controller; window.makeKeyAndVisible(); controller.view.layoutIfNeeded()
    let web = try XCTUnwrap(findWeb(controller.view))
    try await waitForRenderer(web)
    try await Task.sleep(for: .seconds(2))
    var results: [String: Any] = [:]
    results["preferences"] = try await web.evaluateJavaScript("({classes:document.documentElement.className,reducedMotion:matchMedia('(prefers-reduced-motion: reduce)').matches,canvas:document.querySelectorAll('canvas').length})")
    print("CHAT_RENDER_PREFERENCES \(results["preferences"]!)")
    for name in ["Listening", "pepeW"] {
      let bounds: [String: Double] = try await javascript(web, "const node=document.querySelector('.emote.'+name);const r=node.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};", arguments: ["name": name])
      XCTAssertGreaterThanOrEqual(bounds["y"]!, 0, "Full emote must fit within the viewport")
      let capture = WKSnapshotConfiguration()
      capture.rect = CGRect(x: bounds["x"]!, y: bounds["y"]!, width: bounds["width"]!, height: bounds["height"]!)
      var hashes = Set<String>()
      for index in 0..<8 {
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
          web.takeSnapshot(with: capture) { image, error in
            if let image { continuation.resume(returning: image) }
            else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
          }
        }
        let data = try XCTUnwrap(image.pngData())
        hashes.insert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        if index == 0 { let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
        try await Task.sleep(for: .milliseconds(150))
      }
      XCTAssertGreaterThan(hashes.count, 1, "\(name) must display changing pixels through the actual WKURLSchemeHandler")
      results[name] = ["distinct_frame_hashes": hashes.count, "bounds": bounds]
    }
    let reference = WKWebView(frame: CGRect(x: -4000, y: 0, width: web.bounds.width, height: web.bounds.height))
    controller.view.addSubview(reference)
    defer { reference.stopLoading(); reference.removeFromSuperview() }
    reference.loadHTMLString("<style>.emote{display:inline-block;position:relative;overflow:hidden;text-indent:-999em} "
      + styles.replacingOccurrences(of: "dgg-asset:", with: "https:")
      + "</style><div class='msg-chat msg-user'><span class='text'><div class='emote PepoPunch'>PepoPunch </div></span></div>", baseURL: URL(string: "https://www.destiny.gg"))
    for _ in 0..<100 {
      if (try? await reference.evaluateJavaScript("Boolean(document.querySelector('.PepoPunch'))")) as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let sample = "document.getAnimations().forEach(a=>{a.pause();a.currentTime=time});const c=getComputedStyle(document.querySelector('.PepoPunch'));return [c.backgroundPosition,c.transform,c.width,c.animationDuration,c.animationTimingFunction,c.animationIterationCount,c.animationDelay];"
    // PepoPunch deliberately finishes after three loops. Restart both fixtures
    // before sampling: finished animations aren't returned by getAnimations().
    let restart = "const e=document.querySelector('.PepoPunch');e.style.animation='none';void e.offsetWidth;e.style.animation='';return true;"
    let _: Bool = try await javascript(web, restart)
    let _: Bool = try await javascript(reference, restart)
    var samples: [[String: Any]] = []
    for time in [0, 125, 375, 875, 1100, 2750, 4500] {
      let actual: [String] = try await javascript(web, sample, arguments: ["time": time])
      let expected: [String] = try await javascript(reference, sample, arguments: ["time": time])
      XCTAssertEqual(actual, expected, "PepoPunch must match native CSS at \(time) ms")
      samples.append(["time_ms": time, "actual": actual])
    }
    results["PepoPunch"] = samples
    let badges = try await web.evaluateJavaScript("(() => {const row=document.querySelector('.msg-chat');const a=row.querySelector('.flair18').getBoundingClientRect();const b=row.querySelector('.flair127').getBoundingClientRect();return {master_x:a.x,new_badge_x:b.x,new_badge_width:b.width,new_badge_height:b.height,hidden_count:row.querySelectorAll('.flair13').length};})()") as! [String: Double]
    XCTAssertLessThan(badges["master_x"]!, badges["new_badge_x"]!)
    XCTAssertEqual(badges["new_badge_width"], 18); XCTAssertEqual(badges["new_badge_height"], 18)
    XCTAssertEqual(badges["hidden_count"], 0)
    results["badges"] = badges
    let catalog = emotes.catalog.map { ["name": $0.key, "url": $0.value.absoluteString.replacingOccurrences(of: "https:", with: "dgg-asset:")] }
    let decode = "let next=0,success=0,errors=[];await Promise.all(Array.from({length:4},async()=>{while(next<catalog.length){const item=catalog[next++],image=new Image();try{image.src=item.url;await image.decode();if(!image.naturalWidth||!image.naturalHeight)throw Error('Empty image');success++}catch(e){errors.push({name:item.name,url:item.url,error:String(e)})}}}));return {success,errors};"
    let audit: [String: Any] = try await javascript(web, decode, arguments: ["catalog": catalog])
    let failures = audit["errors"] as? [[String: Any]] ?? []
    XCTAssertTrue(failures.isEmpty, "Every current catalog asset must decode through the production loader")
    let direct: [String: Any] = try await javascript(reference, decode, arguments: ["catalog": failures.map { ["name": $0["name"]!, "url": ($0["url"] as! String).replacingOccurrences(of: "dgg-asset:", with: "https:")] }])
    XCTAssertEqual(Set(failures.compactMap { $0["name"] as? String }), Set((direct["errors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }), "Production transport must decode every format supported by this platform's direct first-party renderer")
    results["full_catalog"] = audit
    results["direct_https_format_failures"] = direct
    let loadEvents = "return await Promise.all(catalog.map(item=>new Promise(resolve=>{const image=new Image();image.onload=()=>resolve({name:item.name,loaded:true,width:image.naturalWidth,height:image.naturalHeight});image.onerror=()=>resolve({name:item.name,loaded:false});image.src=item.url})));"
    let failingURLs = failures.map { ["name": $0["name"]!, "url": ($0["url"] as! String).replacingOccurrences(of: "dgg-asset:", with: "https:")] }
    let loads: [[String: Any]] = try await javascript(reference, loadEvents, arguments: ["catalog": failingURLs])
    results["direct_https_load_events"] = loads
    var platformDecoding: [[String: Any]] = []
    for item in failingURLs {
      let (data, _) = try await URLSession.shared.data(from: URL(string: item["url"] as! String)!)
      let source = CGImageSourceCreateWithData(data as CFData, nil)
      let count = source.map { CGImageSourceGetCount($0) } ?? 0
      let decoded = (0..<count).filter { index in
        autoreleasepool { CGImageSourceCreateImageAtIndex(source!, index, [kCGImageSourceShouldCache: false] as CFDictionary) != nil }
      }.count
      var details: [String: Any] = ["name": item["name"]!, "imageio_frames": count, "decoded_frames": decoded,
        "type": source.flatMap { CGImageSourceGetType($0) as String? } ?? "unrecognized"]
      if let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any], JSONSerialization.isValidJSONObject(properties) {
        details["properties"] = properties
      }
      platformDecoding.append(details)
    }
    results["platform_imageio"] = platformDecoding
    snapshot(window, name: "native-emote-validation")
    print("CHAT_NATIVE_VALIDATION " + String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), as: UTF8.self))
  }
}

@MainActor extension ChatBenchmarkTests {
  func testAssetSnapshotPersists() async throws {
    let store = EmoteStore()
    await store.load(force: true)
    XCTAssertNil(store.status)
    let snapshot = try XCTUnwrap(store.snapshot)
    let saved = await store.assets.savedSnapshot()
    XCTAssertEqual(saved, snapshot, "The real application cache location must retain the validated snapshot for restart recovery")
  }

  func testReportedEmotesAnimateInChat() async throws {
    for cold in [true, false] { try await verifyReportedEmotes(cold: cold) }
  }
  private func verifyReportedEmotes(cold: Bool) async throws {
    let store = EmoteStore()
    if cold { await store.clearBenchmarkCache() }
    await store.load(force: true)
    let names = ["ARRIVE", "BlackGuyLaptop", "Classic", "HUH", "COKEJAW"]
    XCTAssertTrue(Set(names).isSubset(of: Set(store.catalog.keys)), "Authoritative catalog unavailable: \(store.status ?? "none")")
    let feed = Feed()
    feed.messages = try names.enumerated().map { index, name in
      let payload = try JSONSerialization.data(withJSONObject: ["uuid": "reported-\(index)", "nick": "Benchmark", "data": name])
      guard case .message(let message) = try ChatProtocol.decode("MSG " + String(decoding: payload, as: UTF8.self)) else { throw URLError(.cannotParseResponse) }
      return message
    }
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let controller = UIHostingController(rootView: Timeline(feed: feed, emotes: store))
    window.rootViewController = controller; window.makeKeyAndVisible(); controller.view.layoutIfNeeded()
    let web = try XCTUnwrap(findWeb(controller.view))
    try await waitForRenderer(web)
    var visible = false
    for _ in 0..<100 {
      controller.view.layoutIfNeeded()
      visible = try await javascript(web, "return document.querySelectorAll('.emote').length===5 && [...document.querySelectorAll('.emote')].every(n=>n.getBoundingClientRect().height>0);")
      if visible { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let readiness: String = try await javascript(web, "return JSON.stringify({width:innerWidth,height:innerHeight,text:document.body.innerText,metrics:ChatRenderer.metrics()});")
    XCTAssertTrue(visible, readiness)
    let _: Bool = try await javascript(web, "await Promise.all([...document.querySelectorAll('.emote')].map(async node=>{const image=new Image();image.src=node.dataset.resource;await image.decode()}));return true;")
    let bounds: [String: [String: Double]] = try await javascript(web, "return Object.fromEntries([...document.querySelectorAll('.emote')].map(node=>{const r=node.getBoundingClientRect();return [node.title,{x:r.x,y:r.y,width:r.width,height:r.height}]}));")
    XCTAssertEqual(Set(bounds.keys), Set(names), "Exact catalog tokens must become emote elements, not plain text")
    var hashes = Dictionary(uniqueKeysWithValues: names.map { ($0, Set<String>()) })
    for index in 0..<8 {
      let image: UIImage = try await withCheckedThrowingContinuation { continuation in
        web.takeSnapshot(with: nil) { image, error in
          if let image { continuation.resume(returning: image) }
          else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
        }
      }
      if index == 0 { let attachment = XCTAttachment(image: image); attachment.name = "reported-emotes"; attachment.lifetime = .keepAlways; add(attachment) }
      for name in names {
        let r = try XCTUnwrap(bounds[name])
        let rect = CGRect(x: r["x"]!, y: r["y"]!, width: r["width"]!, height: r["height"]!).applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
        let data = try XCTUnwrap(UIImage(cgImage: crop).pngData())
        hashes[name]!.insert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    for name in names { XCTAssertGreaterThan(hashes[name]!.count, 1, "\(name) must show changing image pixels") }
    print("REPORTED_EMOTES_\(cold ? "COLD" : "WARM") " + String(decoding: try JSONSerialization.data(withJSONObject: hashes.mapValues(\.count)), as: UTF8.self))
  }

  func testAVIFContainerDiagnosis() async throws {
    let store = EmoteStore()
    await store.load(force: true)
    var results: [[String: Any]] = []
    for name in ["ARRIVE", "BlackGuyLaptop", "Classic", "HUH", "COKEJAW"] {
      let url = try XCTUnwrap(store.catalog[name])
      var request = URLRequest(url: url)
      request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
      let (data, _) = try await URLSession.shared.data(for: request)
      let normalized = ChatImageFormat.normalized(data)
      XCTAssertEqual(ChatImageFormat.normalized(normalized), normalized)
      for (kind, value) in [("original", data), ("normalized", normalized)] {
        let source = CGImageSourceCreateWithData(value as CFData, nil)
        let count = source.map { CGImageSourceGetCount($0) } ?? 0
        var decoded = 0
        if let source { for index in 0..<count {
          autoreleasepool { if CGImageSourceCreateImageAtIndex(source, index, nil) != nil { decoded += 1 } }
        } }
        if kind == "normalized" { XCTAssertGreaterThan(count, 1); XCTAssertEqual(decoded, count) }
        results.append(["name": name, "variant": kind, "frames": count, "decoded": decoded, "bytes": value.count])
      }
    }
    print("AVIF_DIAGNOSIS " + String(decoding: try JSONSerialization.data(withJSONObject: results), as: UTF8.self))
  }
}

@MainActor extension ChatBenchmarkTests {
  func testScrollToBottomButton() async throws {
    guard ChatBenchmarkMetrics.hasScrollToBottom else { throw XCTSkip("Baseline predates the scroll-to-bottom feature") }
    let store = EmoteStore(), chat = ChatStore()
    var messages = (0..<500).map { ChatMessage(payload: ["uuid": "bottom-\($0)", "nick": "EscapeAltDelete", "data": "Message \($0)"]) }
    func list() -> ChatList {
      ChatList(messages: messages, emotes: store, fontSize: 16, timestamps: false,
        onReply: { _ in }, onWhisper: { _ in }, onIgnore: { _ in }, onStream: { _ in }, chat: chat)
    }
    let coordinator = list().makeCoordinator(), web = coordinator.makeWebView()
    defer { coordinator.stop(); web.removeFromSuperview() }
    let window = try XCTUnwrap((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first)
    let host = UIViewController(); host.view.backgroundColor = .systemBackground
    window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(web); web.frame = window.bounds; web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.view.layoutIfNeeded()
    try await waitForRenderer(web)
    let button = try XCTUnwrap(web.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "chatScrollToBottom" })
    for _ in 0..<100 {
      let distance: Double = try await javascript(web, "return Math.abs(document.scrollingElement.scrollHeight-document.scrollingElement.clientHeight-document.scrollingElement.scrollTop);")
      if distance < 2, button.isHidden { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(button.isHidden, "Following live messages needs no floating control")
    for size in [CGSize(width: min(390, window.bounds.width), height: min(600, window.bounds.height)), CGSize(width: window.bounds.width, height: min(360, window.bounds.height))] {
      web.frame.size = size; web.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let _: Bool = try await javascript(web, "dispatchEvent(new PointerEvent('pointerdown'));return true;")
      web.scrollView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
      for _ in 0..<50 {
        let offset: Double = try await javascript(web, "return scrollY;")
        if abs(offset - 500) < 1, abs(web.scrollView.contentOffset.y - 500) < 1, button.alpha == 1 { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let _: Bool = try await javascript(web, "dispatchEvent(new PointerEvent('pointerup'));return true;")
      XCTAssertFalse(button.isHidden)
      XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
      XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
      XCTAssertLessThanOrEqual(button.frame.maxX, web.bounds.width - 10)
      XCTAssertLessThanOrEqual(button.frame.maxY, web.bounds.height - 10)
      let before: Double = try await javascript(web, "return scrollY;")
      XCTAssertEqual(before, 500, accuracy: 1, "Wait for WebKit to apply the requested reading position")
      let incoming = ChatMessage(payload: ["uuid": UUID().uuidString, "nick": "EscapeAltDelete", "data": "Incoming while reading"])
      messages.append(incoming)
      coordinator.parent = list(); coordinator.refresh()
      for _ in 0..<50 {
        let shown: Bool = try await javascript(web, "return Boolean(document.querySelector('[data-message=\"'+id+'\"]'));", arguments: ["id": incoming.id])
        if shown { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let after: Double = try await javascript(web, "return scrollY;")
      XCTAssertEqual(before, after, accuracy: 1, "Reading position survives new arrivals")
      snapshot(window, name: "scroll-to-bottom-\(Int(size.width))-\(Int(size.height))")
      button.sendActions(for: .primaryActionTriggered)
      for _ in 0..<12 {
        messages.append(ChatMessage(payload: ["uuid": UUID().uuidString, "nick": "EscapeAltDelete", "data": "Arriving during jump"]))
        coordinator.parent = list(); coordinator.refresh()
        try await Task.sleep(for: .milliseconds(25))
      }
      for _ in 0..<100 {
        let settled: Bool = try await javascript(web, "return Boolean(document.querySelector('[data-message=\"'+id+'\"]')) && Math.abs(document.scrollingElement.scrollHeight-document.scrollingElement.clientHeight-document.scrollingElement.scrollTop)<2;", arguments: ["id": messages.last!.id])
        if settled, button.isHidden { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let distance: Double = try await javascript(web, "return Math.abs(document.scrollingElement.scrollHeight-document.scrollingElement.clientHeight-document.scrollingElement.scrollTop);")
      XCTAssertLessThan(distance, 2, "The moving target must be the newest message")
      XCTAssertTrue(button.isHidden)
    }
    coordinator.webViewWebContentProcessDidTerminate(web)
    XCTAssertTrue(button.isHidden, "Renderer recovery resets stale presentation")
    try await waitForRenderer(web)
  }
}
