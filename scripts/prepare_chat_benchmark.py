"""Generate an isolated iOS chat benchmark from the actual production sources."""
from pathlib import Path
import shutil
import sys
import os
import json

root = Path("build/chat-benchmark")
source = root / "Sources"
shutil.rmtree(source, ignore_errors=True)
source.mkdir(parents=True, exist_ok=True)
production = Path(sys.argv[1] if len(sys.argv) > 1 else ".") / "Streamstiny"
include_player = os.environ.get("CHAT_INCLUDE_PLAYER") == "1"
names = [*production.glob("Chat*.swift"), *production.glob("Emote*.swift")]
names += [production / name for name in ["AssetDownloadQueue.swift", "StreamSource.swift", "StreamDirectory.swift", "DestinyAccount.swift", "TokenStore.swift"]]
if include_player:
    names = [path for path in production.glob("*.swift") if path.name != "StreamstinyApp.swift"]
if asset_root := os.environ.get("CHAT_ASSET_SOURCE_ROOT"):
    # Explicitly isolate renderer changes when old discovery/format support no
    # longer works with the live upstream catalog. Both copies use the same assets.
    asset_names = ["ChatAssets.swift", "ChatAssetLoader.swift", "ChatImageFormat.swift", "EmoteStore.swift"]
    names = [path for path in names if path.name not in asset_names]
    names += [Path(asset_root) / name for name in asset_names]
for path in names:
    text = path.read_text()
    # The hosted runner forces Reduce Motion. Compare both implementations with
    # animations explicitly enabled; production accessibility behavior is untouched.
    text = text.replace("UIAccessibility.isReduceMotionEnabled", "false")
    if path.name == "EmoteStore.swift":
        # Hold the catalog source constant when measuring the legacy decoder.
        text = text.replace('"https://cdn.destiny.gg/" + path', '"https://r2cdn.destiny.gg/" + path')
        text = text.replace("let (data, response) = try await session.data(from: url)", "ChatBenchmarkMetrics.requests += 1\n        let (data, response) = try await session.data(from: url)\n        ChatBenchmarkMetrics.bytes += data.count")
    if path.name == "ChatList.swift" and "ChatWebCoordinator" in text:
        text = text.replace("      guard ready else { return }", """      guard ready else { return }
      let refreshStarted = ProcessInfo.processInfo.systemUptime
      defer { ChatBenchmarkMetrics.refreshTimes.append((ProcessInfo.processInfo.systemUptime - refreshStarted) * 1000) }""", 1)
    if include_player and path.name == "PlayerView.swift":
        text = text.replace("        let value = !reportsBitrate", "        if reportsBitrate { ChatBenchmarkMetrics.bitrateSamples += 1 }\n        let value = !reportsBitrate")
    (source / path.name).write_text(text)
host = Path("Benchmarks/Chat/Host.swift").read_text()
if include_player:
    start = host.index("enum PlaybackResolver {")
    end = host.index("@MainActor enum ChatBenchmarkMetrics", start)
    host = host[:start] + host[end:]
    host = host.replace("  static var requests = 0", "  static var bitrateSamples = 0\n  static var requests = 0")
if "let assets: ChatAssetLoader" in (source / "EmoteStore.swift").read_text():
    host += '''\n@MainActor extension EmoteStore {
  func benchmarkMetrics() async -> [String: Double] {
    let value = await assets.metrics
    return ["download_calls_cumulative": Double(value.requests), "download_bytes_cumulative": Double(value.bytes),
      "http_cache_hits_cumulative": Double(value.cacheHits), "deduplicated_cumulative": Double(value.deduplicated)]
  }
  var benchmarkStyles: String? { stylesheet }
  func clearBenchmarkCache() async { await assets.clearBenchmarkCache() }
}\n'''
    with (source / "ChatAssetLoader.swift").open("a") as output:
        output.write('''\nextension ChatAssetLoader {
  func clearBenchmarkCache() {
    session.configuration.urlCache?.removeAllCachedResponses()
    if let snapshotURL { try? FileManager.default.removeItem(at: snapshotURL) }
  }
}\n''')
else:
    host += '''\n@MainActor extension EmoteStore {
  func benchmarkMetrics() async -> [String: Double] {
    ["download_calls_cumulative": Double(ChatBenchmarkMetrics.requests), "download_bytes_cumulative": Double(ChatBenchmarkMetrics.bytes)]
  }
  var benchmarkStyles: String? { nil }
}\n'''
    with (source / "EmoteStore.swift").open("a") as output:
        output.write('''\n@MainActor extension EmoteStore {
  func clearBenchmarkCache() async { session.configuration.urlCache?.removeAllCachedResponses() }
}\n''')
(source / "Host.swift").write_text(host)
for path in production.glob("Chat*.js"):
    text = path.read_text().replace("!matchMedia('(prefers-reduced-motion: reduce)').matches", "true")
    if include_player and path.name == "PlayerView.swift":
        text = text.replace("        let value = !reportsBitrate", "        if reportsBitrate { ChatBenchmarkMetrics.bitrateSamples += 1 }\n        let value = !reportsBitrate")
    (source / path.name).write_text(text)
shutil.copy("Benchmarks/Chat/ChatBenchmarkTests.swift", root)
shutil.copy("Benchmarks/Chat/NativeEmoteChecks.swift", root)
(root / "project.yml").write_text("""name: ChatBenchmark
options:
  deploymentTarget:
    iOS: '17.0'
settings:
  base:
    SWIFT_VERSION: '5.0'
    CODE_SIGNING_ALLOWED: NO
    GENERATE_INFOPLIST_FILE: YES
    SWIFT_OPTIMIZATION_LEVEL: '-O'
    ENABLE_TESTABILITY: YES
    SUPPORTS_MACCATALYST: YES
    DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO
targets:
  ChatBenchmark:
    type: application
    platform: iOS
    sources: [Sources]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: gg.streamstiny.chatbenchmark
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
  ChatBenchmarkTests:
    type: bundle.unit-test
    platform: iOS
    sources: [ChatBenchmarkTests.swift, NativeEmoteChecks.swift]
    dependencies:
      - target: ChatBenchmark
schemes:
  ChatBenchmark:
    build:
      targets:
        ChatBenchmark: all
        ChatBenchmarkTests: [test]
    test:
      targets: [ChatBenchmarkTests]
""")
if include_player:
    shutil.copy("Benchmarks/Chat/PlayerAcceptanceTests.swift", root)
    project = root / "project.yml"
    text = project.read_text().replace("options:\n", "include: [../../dependencies.yml]\noptions:\n", 1)
    text = text.replace("    sources: [Sources]", "    sources: [Sources]\n    dependencies:\n      - package: KSPlayer", 1)
    text = text.replace("NativeEmoteChecks.swift]", "NativeEmoteChecks.swift, PlayerAcceptanceTests.swift]")
    text = text.replace("        INFOPLIST_KEY_UILaunchScreen_Generation: YES", "        INFOPLIST_KEY_UILaunchScreen_Generation: YES\n        INFOPLIST_KEY_NSAppTransportSecurity_NSAllowsLocalNetworking: YES")
    project.write_text(text)
if (source / "ChatRenderer.js").exists():
    project = root / "project.yml"
    project.write_text(project.read_text().replace("sources: [Sources]", """sources:
      - path: Sources
        excludes: [ChatRenderer.js]
      - path: Sources/ChatRenderer.js
        buildPhase: resources"""))

# Apple's documented iOS 18.5 Simulator loader fix; deployment stays at iOS 17.
# https://bugs.webkit.org/show_bug.cgi?id=293831
if swift_libraries := os.environ.get("CHAT_SIMULATOR_SWIFT_LIBRARIES"):
    project = root / "project.yml"
    environment = "      environmentVariables:\n        DYLD_FALLBACK_LIBRARY_PATH: " + json.dumps(swift_libraries) + "\n"
    project.write_text(project.read_text().replace("    test:\n", "    run:\n" + environment + "    test:\n" + environment))
