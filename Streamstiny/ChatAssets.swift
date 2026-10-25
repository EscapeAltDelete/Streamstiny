import Foundation

struct Emote: Codable, Equatable, Sendable {
  let prefix: String
  let image: [Image]
  let minimumSubTier: Int
  let patreonOnly: Bool
  struct Image: Codable, Equatable, Sendable {
    let url: URL?
    let width: Double?
    let height: Double?
  }
  private enum CodingKeys: String, CodingKey { case prefix, image, minimumSubTier, patreonOnly }
  init(from decoder: Decoder) throws {
    let value = try decoder.container(keyedBy: CodingKeys.self)
    prefix = try value.decode(String.self, forKey: .prefix)
    image = try value.decode([Image].self, forKey: .image)
    minimumSubTier = try value.decodeIfPresent(Int.self, forKey: .minimumSubTier) ?? 0
    patreonOnly = try value.decodeIfPresent(Bool.self, forKey: .patreonOnly) ?? false
  }
  func allows(_ user: ChatUser?) -> Bool {
    user?.privileged == true || (patreonOnly ? user?.patreonMember == true : minimumSubTier <= (user?.tier ?? 0))
  }
}

struct ChatFlair: Codable, Equatable, Sendable {
  let name: String
  let label: String
  let priority: Int
  let hidden: Bool
  let color: String?
  let rainbowColor: Bool?
  let description: String?
  let image: [Emote.Image]?
}

struct ChatAssetConfiguration: Codable, Equatable, Sendable {
  let base: URL
  let cacheKey: String

  // The production embed page is the same configuration source as the website.
  static func discover(in html: String) throws -> Self {
    func attribute(_ name: String) -> String? {
      let rule = try? NSRegularExpression(pattern: name + #"\s*=\s*["']([^"']*)["']"#)
      guard let match = rule?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
        let range = Range(match.range(at: 1), in: html) else { return nil }
      return String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
    }
    guard let address = attribute("data-cdn"), let base = URL(string: address),
      base.scheme == "https", let host = base.host, host.hasSuffix(".destiny.gg"),
      base.user == nil, base.password == nil, base.port == nil,
      base.query == nil, base.fragment == nil, base.path.isEmpty || base.path == "/",
      let key = attribute("data-cache-key"), key.count <= 200 else { throw URLError(.badServerResponse) }
    return Self(base: base, cacheKey: key)
  }
  func url(_ path: String) -> URL {
    var value = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    value.queryItems = [URLQueryItem(name: "_", value: cacheKey)]
    return value.url!
  }
  static func proxied(_ url: URL) -> URL? {
    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      var value = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
    value.scheme = "dgg-asset"
    return value.url
  }
  static func original(_ url: URL) -> URL? {
    guard url.scheme == "dgg-asset", var value = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
    value.scheme = "https"
    value.queryItems = value.queryItems?.filter { $0.name != "__streamstiny_retry" }
    if value.queryItems?.isEmpty == true { value.queryItems = nil }
    guard let result = value.url, proxied(result) != nil else { return nil }
    return result
  }

  // Preserve the authoritative CSS verbatim except for routing image URLs through
  // the shared loader. WebKit interprets keyframes, steps, delays and selectors.
  static func stylesheet(_ css: String, relativeTo base: URL) -> String {
    let rule = try! NSRegularExpression(pattern: #"url\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)]*))\s*\)"#)
    var result = css
    for match in rule.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
      guard let group = (1...3).first(where: { match.range(at: $0).location != NSNotFound }),
        let range = Range(match.range(at: group), in: css), let whole = Range(match.range, in: result) else { continue }
      let address = String(css[range])
      guard !address.hasPrefix("#"), let url = URL(string: address, relativeTo: base)?.absoluteURL,
        let proxy = proxied(url) else { continue }
      result.replaceSubrange(whole, with: "url(\"" + proxy.absoluteString + "\")")
    }
    return result
  }
}

struct ChatAssetSnapshot: Codable, Equatable, Sendable {
  let configuration: ChatAssetConfiguration
  let emotes: [Emote]
  let flairs: [ChatFlair]
  let stylesheet: String
  init(configuration: ChatAssetConfiguration, emotes: [Emote], flairs: [ChatFlair], emoteCSS: String, flairCSS: String) {
    self.configuration = configuration
    self.emotes = emotes
    self.flairs = flairs
    stylesheet = ChatAssetConfiguration.stylesheet(emoteCSS, relativeTo: configuration.url("emotes/emotes.css"))
      + "\n" + ChatAssetConfiguration.stylesheet(flairCSS, relativeTo: configuration.url("flairs/flairs.css"))
  }
}
