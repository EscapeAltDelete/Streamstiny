import ImageIO
import Observation
import UIKit

struct Emote: Decodable, Sendable {
  let prefix: String
  let image: EmoteImage
  let minimumSubTier: Int
  let twitch: Bool
  struct EmoteImage: Decodable, Sendable {
    let url: String
    let width: Double?
    let height: Double?
  }
  private enum CodingKeys: String, CodingKey { case prefix, image, minimumSubTier, twitch }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    prefix = try container.decode(String.self, forKey: .prefix)
    minimumSubTier = try container.decodeIfPresent(Int.self, forKey: .minimumSubTier) ?? 0
    twitch = try container.decodeIfPresent(Bool.self, forKey: .twitch) ?? false
    if let variants = try? container.decode([EmoteImage].self, forKey: .image),
      let first = variants.first
    {
      image = first
    } else {
      image = try container.decode(EmoteImage.self, forKey: .image)
    }
  }
}

struct ChatFlair: Decodable {
  let name: String
  let label: String
  let priority: Int
  let hidden: Bool
  let color: String?
  let rainbowColor: Bool?
  let description: String?
  struct Image: Decodable {
    let url: String?
    let width: Double?
    let height: Double?
  }
  let image: [Image]?

  static func visible(in flairs: [ChatFlair], features: [String]) -> [ChatFlair] {
    features.enumerated().compactMap { index, name -> (Int, ChatFlair)? in
      guard let flair = flairs.first(where: { $0.name == name }), !flair.hidden,
        let image = flair.image?.first, image.url != nil,
        let width = image.width, width > 0, let height = image.height, height > 0 else { return nil }
      return (index, flair)
    }.sorted {
      $0.1.priority == $1.1.priority ? $0.0 < $1.0 : $0.1.priority < $1.1.priority
    }.map { $0.1 }
  }
}

@MainActor @Observable final class EmoteStore {
  private(set) var catalog: [String: URL] = [:]
  private(set) var flairs: [ChatFlair] = []
  private(set) var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favoriteEmotes") ?? [])
  func favorite(_ name: String) {
    if favorites.contains(name) { favorites.remove(name) } else { favorites.insert(name) }
    UserDefaults.standard.set(Array(favorites).sorted(), forKey: "favoriteEmotes")
  }
  func refreshPreferences() {
    favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteEmotes") ?? [])
    revision += 1
  }
  private var previewURLs: [String: URL] = [:]
  private var flairURLs: [String: URL] = [:]
  private var requirements: [String: Emote] = [:]
  func canUse(_ word: String, user: ChatUser?) -> Bool {
    guard let emote = requirements[word] else { return false }
    if user?.privileged == true { return true }
    if emote.twitch { return user?.features.contains("flair9") == true }
    return (user?.tier ?? 0) >= emote.minimumSubTier
  }
  func displaySize(for word: String, lineHeight: CGFloat) -> CGSize {
    let metadata = requirements[word]?.image
    let declared = metadata.flatMap { image -> CGSize? in
      guard let width = image.width, let height = image.height,
        width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
      return CGSize(width: width, height: height)
    }
    // CSS sprite frame dimensions take precedence over the full image size.
    // Never size a row from an asynchronously downloaded/evicted bitmap.
    let native = frames[word] ?? declared ?? CGSize(width: 28, height: 28)
    return ChatAttachmentSize.fitted(native, maximum: CGSize(width: 100, height: min(lineHeight * 1.25, 36)))
  }
  func usernameColor(features: [String]) -> UIColor? {
    guard let text = flairs.first(where: { features.contains($0.name) && ($0.rainbowColor == true || $0.color?.isEmpty == false) })?.color,
      let value = UInt32(text.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
    else { return nil }
    return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
      blue: CGFloat(value & 255) / 255, alpha: 1)
  }
  func rainbowName(_ name: String, features: [String], font: UIFont) -> UIImage? {
    guard flairs.first(where: { features.contains($0.name) && ($0.color?.isEmpty == false || $0.rainbowColor == true) })?.rainbowColor == true else { return nil }
    let key = "rainbow:\(font.pointSize):\(name)" as NSString
    if let image = images.object(forKey: key) { return image }
    let size = (name as NSString).size(withAttributes: [.font: font])
    guard size.width > 0, size.width < 1000 else { return nil }
    let frames = (0..<12).map { phase in
      UIGraphicsImageRenderer(size: size).image { _ in
        let text = NSMutableAttributedString(string: name, attributes: [.font: font])
        for index in 0..<text.length {
          let hue = (Double(index) / Double(max(1, text.length)) + Double(phase) / 12).truncatingRemainder(dividingBy: 1)
          text.addAttribute(.foregroundColor, value: UIColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1), range: NSRange(location: index, length: 1))
        }
        text.draw(at: .zero)
      }
    }
    guard let image = UIImage.animatedImage(with: frames, duration: 3) else { return nil }
    images.setObject(image, forKey: key, cost: Self.cost(image))
    return image
  }
  func preview(_ url: URL) -> UIImage? {
    guard url.scheme == "https", ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased()) else { return nil }
    let key = "preview:" + url.absoluteString
    if previewURLs.count >= 100, previewURLs[key] == nil, let oldest = previewURLs.keys.first {
      previewURLs.removeValue(forKey: oldest)
      failed.remove(oldest)
    }
    previewURLs[key] = url
    return image(for: key)
  }
  func combining(_ messages: [ChatMessage]) -> [ChatMessage] {
    if UserDefaults.standard.bool(forKey: "disableEmoteCombos") { return messages }
    var result: [ChatMessage] = []
    for message in messages {
      let user = message.user
      let emote = message.text.hasPrefix("/me ") ? String(message.text.dropFirst(4)) : message.text
      guard message.kind == "MSG", !message.whisper, !message.removed, canUse(emote, user: user) else { result.append(message); continue }
      if let last = result.last, last.kind == "MSG", !last.removed, last.text == message.text, !last.comboNicks.isEmpty {
        result[result.count - 1].comboNicks.append(message.nick)
      } else {
        var entry = message
        entry.comboNicks = [message.nick]
        result.append(entry)
      }
    }
    return result
  }
  private(set) var revision = 0
  private(set) var status: String?
  @ObservationIgnored private var downloadQueue = AssetDownloadQueue<String>()
  private let images = NSCache<NSString, UIImage>()
  @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var suspended = false
  @ObservationIgnored private var failed: Set<String> = []
  private var frames: [String: CGSize] = [:]
  private var durations: [String: Double] = [:]
  @ObservationIgnored private var assetLoad: Task<Bool, Never>?
  @ObservationIgnored private var assetGeneration = 0
  @ObservationIgnored private var nextAssetRefresh = Date.distantPast
  private let session: URLSession

  init() {
    images.totalCostLimit = 16 * 1024 * 1024
    images.countLimit = 300
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 4
    config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024)
    config.timeoutIntervalForRequest = 15
    config.httpAdditionalHeaders = ["User-Agent": PlaybackResolver.userAgent]
    session = URLSession(configuration: config)
  }

  deinit { session.invalidateAndCancel() }

  func load(force: Bool = false) async {
    guard !suspended else { return }
    if let assetLoad { _ = await assetLoad.value; return }
    guard force || Date() >= nextAssetRefresh else { return }
    let version = assetGeneration
    let work = Task { [weak self] in await self?.loadAssets() ?? false }
    assetLoad = work
    let success = await work.value
    guard assetGeneration == version else { return }
    assetLoad = nil
    nextAssetRefresh = Date().addingTimeInterval(success ? 1800 : 30)
  }

  private func loadAssets() async -> Bool {
    async let emoteData = asset("emotes/emotes.json")
    async let flairData = asset("flairs/flairs.json")
    async let styleData = asset("emotes/emotes.css")
    let (emoteBytes, flairBytes, styleBytes) = await (emoteData, flairData, styleData)
    guard !Task.isCancelled else { return false }
    let oldCatalog = catalog, oldFlairURLs = flairURLs
    let oldFrames = frames, oldDurations = durations
    var loadedEmotes = false, loadedFlairs = false
    if let data = emoteBytes, let values = try? JSONDecoder().decode([Emote].self, from: data) {
      loadedEmotes = true
      requirements = Dictionary(values.map { ($0.prefix, $0) }, uniquingKeysWith: { _, new in new })
      catalog = Dictionary(values.compactMap { item in
        guard let url = URL(string: item.image.url), url.scheme == "https" else { return nil }
        return (item.prefix, url)
      }, uniquingKeysWith: { _, new in new })
    }
    if let data = flairBytes, let values = try? JSONDecoder().decode([ChatFlair].self, from: data) {
      loadedFlairs = true
      flairs = values.sorted { $0.priority < $1.priority }
      flairURLs = Dictionary(values.compactMap { flair in
        guard let address = flair.image?.first?.url, let url = URL(string: address), url.scheme == "https" else { return nil }
        return ("flair:" + flair.name, url)
      }, uniquingKeysWith: { _, new in new })
    }
    if let styleBytes {
      let metadata = Self.metadata(in: String(decoding: styleBytes, as: UTF8.self))
      frames = metadata.frames; durations = metadata.durations
    }
    if oldCatalog != catalog || oldFlairURLs != flairURLs || oldFrames != frames || oldDurations != durations {
      releaseMemory()
    } else { revision += 1 }

    status = flairs.isEmpty ? "Badges could not be loaded." : catalog.isEmpty ? "Emotes could not be loaded." : nil
    return loadedEmotes && loadedFlairs && styleBytes != nil
  }
  private func asset(_ path: String) async -> Data? {
    do {
      let request = URLRequest(url: URL(string: "https://cdn.destiny.gg/" + path)!, cachePolicy: .reloadRevalidatingCacheData)
      let (data, response) = try await session.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1024 * 1024 else { return nil }
      return data
    } catch { return nil }
  }

  func image(for word: String) -> UIImage? {
    // Views observe completions, rather than every internal queue mutation.
    _ = revision
    if let image = images.object(forKey: word as NSString) { return image }
    guard catalog[word] != nil || flairURLs[word] != nil || previewURLs[word] != nil,
      !suspended, !failed.contains(word) else { return nil }
    for key in downloadQueue.enqueue(word) { startDownload(key) }
    return nil
  }

  private func startDownload(_ word: String) {
    guard let url = catalog[word] ?? flairURLs[word] ?? previewURLs[word] else {
      for key in downloadQueue.finish(word) { startDownload(key) }
      return
    }
    let generation = generation
    let frame = frames[word]
    let duration = durations[word]
    downloads[word] = Task { [weak self, session] in
      defer {
        if let self, self.generation == generation {
          self.downloads[word] = nil
          for key in self.downloadQueue.finish(word) { self.startDownload(key) }
        }
      }
      do {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2 * 1024 * 1024,
          let image = await Self.decode(data, size: frame, duration: duration)
        else { throw URLError(.cannotDecodeContentData) }
        guard !Task.isCancelled, self?.generation == generation,
          (self?.catalog[word] ?? self?.flairURLs[word] ?? self?.previewURLs[word]) == url else { return }
        self?.images.setObject(image, forKey: word as NSString, cost: Self.cost(image))
        self?.revision += 1
      } catch {
        guard !Task.isCancelled, self?.generation == generation else { return }
        self?.failed.insert(word)
      }
    }
  }

  func releaseMemory(suspend: Bool? = nil) {
    generation += 1
    suspended = suspend ?? suspended
    if suspended {
      assetGeneration += 1
      assetLoad?.cancel()
      assetLoad = nil
    }
    for task in downloads.values { task.cancel() }
    downloads.removeAll()
    downloadQueue.removeAll()
    images.removeAllObjects()
    failed.removeAll()
    revision += 1
  }

  func resume() {
    guard suspended else { return }
    suspended = false
    revision += 1
  }

  nonisolated static func cost(_ image: UIImage) -> Int {
    // Timing repeats frame references; count each decoded bitmap once.
    var seen: Set<ObjectIdentifier> = []
    return (image.images ?? [image]).reduce(0) { total, frame in
      guard let bitmap = frame.cgImage, seen.insert(ObjectIdentifier(bitmap)).inserted else {
        return total
      }
      return total + bitmap.bytesPerRow * bitmap.height
    }
  }

  nonisolated static func decode(_ data: Data, size: CGSize?, duration: Double?) async -> UIImage? {
    let work = Task.detached(priority: .utility) { () -> UIImage? in
      guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
      let count = CGImageSourceGetCount(source)
      guard count > 0, count <= 240 else { return nil }
      var images: [UIImage] = []
      var delays: [Double] = []
      if count > 1 {
        for index in 0..<count {
          guard !Task.isCancelled,
            let frame = CGImageSourceCreateThumbnailAtIndex(
              source, index,
              [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 100,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
          else { return nil }
          images.append(UIImage(cgImage: frame))
          let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
          let timing = properties?.values.compactMap { $0 as? [String: Any] }.first {
            $0["DelayTime"] != nil || $0["UnclampedDelayTime"] != nil
          }
          delays.append(
            max(
              0.02,
              (timing?["UnclampedDelayTime"] as? Double)
                ?? (timing?["DelayTime"] as? Double) ?? 0.1))
        }
      } else {
        guard let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil),
          bitmap.width <= 32768, bitmap.height <= 4096,
          bitmap.width * bitmap.height <= 4 * 1024 * 1024
        else { return nil }
        let viewport = size.flatMap { value -> CGSize? in
          value.width > 0 && value.height > 0 && value.width <= CGFloat(bitmap.width)
            && value.height <= CGFloat(bitmap.height) ? value : nil
        }
        let width = Int(viewport?.width ?? CGFloat(bitmap.width))
        let height = Int(viewport?.height ?? CGFloat(bitmap.height))
        guard width > 0, height > 0 else { return nil }
        let frames = duration == nil ? 1 : min(240, max(1, bitmap.width / width))
        for index in 0..<frames {
          guard !Task.isCancelled else { return nil }
          guard
            let crop = bitmap.cropping(
              to: CGRect(
                x: index * width, y: 0,
                width: min(width, bitmap.width), height: min(height, bitmap.height)))
          else { return nil }
          let scale = min(1, min(100 / CGFloat(crop.width), 72 / CGFloat(crop.height)))
          let targetWidth = max(1, Int(CGFloat(crop.width) * scale))
          let targetHeight = max(1, Int(CGFloat(crop.height) * scale))
          guard
            let context = CGContext(
              data: nil, width: targetWidth, height: targetHeight,
              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          else { return nil }
          context.draw(crop, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
          guard let frame = context.makeImage() else { return nil }
          images.append(UIImage(cgImage: frame))
        }
        delays = Array(repeating: (duration ?? 0.1) / Double(frames), count: frames)
      }
      guard !images.isEmpty else { return nil }
      if images.count == 1 { return images[0] }
      // UIImageView uses uniform frame times; repeat references to preserve GIF timing.
      let quantum = max(0.02, (delays.min() ?? 0.1))
      var timeline: [UIImage] = []
      for (image, delay) in zip(images, delays) {
        let repeats = min(50, max(1, Int((delay / quantum).rounded())))
        guard timeline.count + repeats <= 1200 else { return nil }
        timeline.append(contentsOf: repeatElement(image, count: repeats))
      }
      return UIImage.animatedImage(with: timeline, duration: delays.reduce(0, +))
    }
    return await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
  }

  // CSS contains the frame viewport, which can differ from the full sprite-sheet dimensions.
  nonisolated private static let rule = try? NSRegularExpression(
    pattern: #"(?m)^\.emote\.([\w-]+)\s*\{([^}]*)\}"#)
  nonisolated private static let dimension = try? NSRegularExpression(
    pattern: #"(?:^|[;\s])(width|height)\s*:\s*([\d.]+)px"#)
  nonisolated private static let seconds = try? NSRegularExpression(
    pattern: #"animation\s*:[^;]*?([\d.]+)(ms|s)\b"#)

  nonisolated private static func metadata(in style: String)
    -> (frames: [String: CGSize], durations: [String: Double])
  {
    guard let rule, let dimension, let seconds else { return ([:], [:]) }
    var sizes: [String: CGSize] = [:]
    var durations: [String: Double] = [:]
    for match in rule.matches(in: style, range: NSRange(style.startIndex..., in: style)) {
      guard let nameRange = Range(match.range(at: 1), in: style),
        let bodyRange = Range(match.range(at: 2), in: style)
      else { continue }
      let name = String(style[nameRange])
      let body = String(style[bodyRange])
      var size = sizes[name] ?? .zero
      for value in dimension.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
        guard let axis = Range(value.range(at: 1), in: body),
          let number = Range(value.range(at: 2), in: body), let pixels = Double(body[number])
        else { continue }
        if body[axis] == "width" { size.width = pixels } else { size.height = pixels }
      }
      if size.width > 0 && size.height > 0 { sizes[name] = size }
      if let timing = seconds.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
        let value = Range(timing.range(at: 1), in: body),
        let unit = Range(timing.range(at: 2), in: body), let number = Double(body[value])
      {
        durations[name] = max(0.02, number / (body[unit] == "ms" ? 1000 : 1))
      }
    }
    return (sizes, durations)
  }

}
