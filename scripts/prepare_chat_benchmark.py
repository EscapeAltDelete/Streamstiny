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
names = [*production.glob("Chat*.swift"), *production.glob("Emote*.swift")]
names += [production / name for name in ["AssetDownloadQueue.swift", "StreamSource.swift", "StreamDirectory.swift", "DestinyAccount.swift", "TokenStore.swift"]]
for path in names:
    text = path.read_text()
    # The hosted runner forces Reduce Motion. Compare both implementations with
    # animations explicitly enabled; production accessibility behavior is untouched.
    text = text.replace("UIAccessibility.isReduceMotionEnabled", "false")
    if path.name == "EmoteStore.swift":
        # Hold the catalog source constant when measuring the legacy decoder.
        text = text.replace('"https://cdn.destiny.gg/" + path', '"https://r2cdn.destiny.gg/" + path')
        text = text.replace("let (data, response) = try await session.data(from: url)", "ChatBenchmarkMetrics.requests += 1\n        let (data, response) = try await session.data(from: url)\n        ChatBenchmarkMetrics.bytes += data.count")
    (source / path.name).write_text(text)
host = Path("Benchmarks/Chat/Host.swift").read_text()
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
  func clearBenchmarkCache() { session.configuration.urlCache?.removeAllCachedResponses() }
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
