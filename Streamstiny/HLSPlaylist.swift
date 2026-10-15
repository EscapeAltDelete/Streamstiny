import Foundation

struct HLSVariant: Identifiable, Equatable, Sendable {
  let url: URL
  let width: Int
  let height: Int
  let bandwidth: Double
  let frameRate: Double
  let externalMedia: Bool
  var codecs: String = ""
  var id: String { "\(width)x\(height):\(Int(frameRate.rounded())):\(externalMedia):\(codecs)" }
  var label: String {
    guard height > 0 else { return "Source" }
    let codec = codecs.lowercased()
    let suffix = codec.contains("hvc") || codec.contains("hev") || codec.contains("h265") ? " · HEVC" : ""
    return "\(height)p" + (frameRate > 30 ? " · \(Int(frameRate.rounded())) fps" : "") + suffix
  }
}

enum HLSPlaylist {
  private static let attributePattern = try? NSRegularExpression(
    pattern: #"([A-Z0-9-]+)=("[^"]*"|[^,\r\n]*)"#)
  // An ended or immutable media playlist does not need the live decoder.
  static func isLive(_ text: String) -> Bool? {
    guard text.hasPrefix("#EXTM3U") else { return nil }
    let lines = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if lines.contains("#EXT-X-ENDLIST") || lines.contains("#EXT-X-PLAYLIST-TYPE:VOD") {
      return false
    }
    if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) { return nil }
    return lines.contains(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") }) ? true : nil
  }

  static func attributes(_ line: String) -> [String: String] {
    guard let regex = attributePattern else { return [:] }
    var result: [String: String] = [:]
    for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
      guard let key = Range(match.range(at: 1), in: line),
        let value = Range(match.range(at: 2), in: line)
      else { continue }
      result[String(line[key])] = String(line[value]).trimmingCharacters(
        in: CharacterSet(charactersIn: "\""))
    }
    return result
  }

  static func variants(_ text: String, base: URL) -> [HLSVariant] {
    guard text.hasPrefix("#EXTM3U") else { return [] }
    let lines = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let externalGroups = Set(
      lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") }.compactMap { line -> String? in
        let fields = attributes(line)
        return fields["URI"] == nil ? nil : fields["GROUP-ID"]
      })
    var pending: [String: String]?
    var result: [HLSVariant] = []
    var seen: Set<String> = []
    for line in lines {
      if line.hasPrefix("#EXT-X-STREAM-INF:") {
        pending = attributes(line)
        continue
      }
      guard !line.isEmpty, !line.hasPrefix("#"), let fields = pending else { continue }
      pending = nil
      let dimensions = (fields["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
      let sourceVideo = dimensions == [0, 0] && fields["VIDEO"] != nil
      let bandwidth = Double(fields["BANDWIDTH"] ?? "") ?? 0
      let frameRate = Double(fields["FRAME-RATE"] ?? "") ?? 0
      guard dimensions.count == 2,
        sourceVideo || dimensions.allSatisfy({ $0 > 0 && $0 <= 16_384 }),
        bandwidth.isFinite, bandwidth >= 0, bandwidth <= 1_000_000_000,
        frameRate.isFinite, frameRate >= 0, frameRate <= 240,
        let url = URL(string: line, relativeTo: base)?.absoluteURL,
        url.scheme == "https", url.host != nil, url.user == nil, url.password == nil
      else { continue }
      let external = [fields["AUDIO"], fields["VIDEO"]].compactMap { $0 }.contains {
        externalGroups.contains($0)
      }
      let variant = HLSVariant(
        url: url, width: dimensions[0], height: dimensions[1],
        bandwidth: bandwidth,
        frameRate: frameRate, externalMedia: external, codecs: fields["CODECS"] ?? "")
      if seen.insert(variant.id).inserted { result.append(variant) }
    }
    return result.sorted {
      $0.height == $1.height ? $0.bandwidth > $1.bandwidth : $0.height > $1.height
    }
  }
}

enum AngelEdge: String, CaseIterable, Identifiable, Sendable {
  case newYork = "nyc1"
  case sanFrancisco = "sfo1"
  case amsterdam = "ams1"
  case frankfurt = "fra1"
  case singapore = "sgp1"
  var id: String { rawValue }
  var name: String {
    switch self {
    case .newYork: return "New York"
    case .sanFrancisco: return "San Francisco"
    case .amsterdam: return "Amsterdam"
    case .frankfurt: return "Frankfurt"
    case .singapore: return "Singapore"
    }
  }
  func replacingHost(in url: URL) -> URL? {
    guard url.scheme == "https", let host = url.host,
      host.hasSuffix(".angelthump.com"),
      !["vigor.angelthump.com", "api.angelthump.com"].contains(host),
      url.path.hasPrefix("/hls/")
    else { return nil }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.host = "\(rawValue).angelthump.com"
    return components?.url
  }
}
