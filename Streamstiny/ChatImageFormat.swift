import Foundation

// Some libavif sequences declare alpha for the primary image but omit the
// equivalent auxiliary handler/declaration from its movie track. Preserve every AV1 sample,
// timestamp and file offset while completing that container metadata.
enum ChatImageFormat {
  private struct Box {
    let start: Int, end: Int, type: String
    var range: Range<Int> { start..<end }
  }
  private static func boxes(_ data: Data, in range: Range<Int>) -> [Box]? {
    var result: [Box] = [], offset = range.lowerBound
    while offset < range.upperBound {
      guard result.count < 4096, range.upperBound - offset >= 8 else { return nil }
      let size = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
      guard size >= 8, size <= range.upperBound - offset,
        let type = String(data: data[offset + 4..<offset + 8], encoding: .ascii) else { return nil }
      result.append(Box(start: offset, end: offset + size, type: type)); offset += size
    }
    return result
  }
  private static func sized(_ data: Data) -> Data {
    var result = data, size = UInt32(data.count).bigEndian
    withUnsafeBytes(of: &size) { result.replaceSubrange(0..<4, with: $0) }
    return result
  }
  static func normalized(_ data: Data) -> Data {
    guard data.count < 16 * 1024 * 1024, let roots = boxes(data, in: 0..<data.count),
      let brand = roots.first, brand.type == "ftyp", brand.end >= 12,
      String(data: data[8..<12], encoding: .ascii) == "avis",
      roots.contains(where: { $0.type == "mdat" }),
      let meta = roots.first(where: { $0.type == "meta" }), meta.end - meta.start >= 12,
      let properties = boxes(data, in: meta.start + 12..<meta.end)?.first(where: { $0.type == "iprp" }),
      let container = boxes(data, in: properties.start + 8..<properties.end)?.first(where: { $0.type == "ipco" }),
      let entries = boxes(data, in: container.start + 8..<container.end),
      let alpha = entries.first(where: { $0.type == "auxC" }), entries.filter({ $0.type == "auxC" }).count == 1,
      data[alpha.start + 8..<alpha.end] == Data([0, 0, 0, 0]) + Data("urn:mpeg:mpegB:cicp:systems:auxiliary:alpha\0".utf8),
      let movie = roots.first(where: { $0.type == "moov" }),
      let tracks = boxes(data, in: movie.start + 8..<movie.end) else { return data }
    let auxiliary = tracks.filter { track in
      guard track.type == "trak", let reference = boxes(data, in: track.start + 8..<track.end)?.first(where: { $0.type == "tref" }) else { return false }
      return boxes(data, in: reference.start + 8..<reference.end)?.contains(where: { $0.type == "auxl" }) == true
    }
    guard auxiliary.count == 1 else { return data }
    var declaration = Data(data[alpha.range])
    declaration.replaceSubrange(4..<8, with: Data("auxi".utf8))
    var changed = false
    func repair(_ box: Box, depth: Int = 0) -> Data {
      guard depth <= 5 else { return Data(data[box.range]) }
      if box.type == "hdlr", box.end - box.start >= 24,
        String(data: data[box.start + 16..<box.start + 20], encoding: .ascii) == "pict" {
        var handler = Data(data[box.range])
        handler.replaceSubrange(16..<20, with: Data("auxv".utf8)); changed = true
        return handler
      }
      let prefix: Int
      switch box.type {
      case "trak", "mdia", "minf", "stbl": prefix = 8
      case "stsd": prefix = 16
      case "av01": prefix = 86
      default: return Data(data[box.range])
      }
      guard box.end - box.start >= prefix, let children = boxes(data, in: box.start + prefix..<box.end) else { return Data(data[box.range]) }
      if box.type == "av01" {
        guard children.contains(where: { $0.type == "av1C" }), !children.contains(where: { $0.type == "auxi" }) else { return Data(data[box.range]) }
        changed = true
        return sized(Data(data[box.range]) + declaration)
      }
      var result = Data(data[box.start..<box.start + prefix])
      for child in children { result.append(repair(child, depth: depth + 1)) }
      return sized(result)
    }
    var rebuilt = Data(data[movie.start..<movie.start + 8])
    for track in tracks { rebuilt.append(track.start == auxiliary[0].start ? repair(track) : Data(data[track.range])) }
    guard changed else { return data }
    // Leave padding in place instead of shifting mdat and invalidating iloc,
    // stco or co64 offsets. Appending moov is a normal ISO-BMFF arrangement.
    var result = data
    result.replaceSubrange(movie.start + 4..<movie.start + 8, with: Data("free".utf8))
    result.append(sized(rebuilt))
    return result
  }
}
