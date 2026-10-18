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
      platformDecoding.append(["name": item["name"]!, "imageio_frames": count, "decoded_frames": decoded,
        "type": source.flatMap { CGImageSourceGetType($0) as String? } ?? "unrecognized"])
    }
    results["platform_imageio"] = platformDecoding
    snapshot(window, name: "native-emote-validation")
    print("CHAT_NATIVE_VALIDATION " + String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), as: UTF8.self))
  }
}
