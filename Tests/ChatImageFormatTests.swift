import Foundation

enum ChatImageFormatTests {
  static func run() {
    func box(_ type: String, _ body: Data) -> Data {
      var size = UInt32(body.count + 8).bigEndian
      return withUnsafeBytes(of: &size) { Data($0) } + Data(type.utf8) + body
    }
    let alpha = Data([0, 0, 0, 0]) + Data("urn:mpeg:mpegB:cicp:systems:auxiliary:alpha\0".utf8)
    let metadata = box("meta", Data(repeating: 0, count: 4) + box("iprp", box("ipco", box("auxC", alpha))))
    let prefix = box("ftyp", Data("avis".utf8) + Data(repeating: 0, count: 4) + Data("avifavis".utf8)) + metadata
    let video = Data(repeating: 0, count: 78) + box("av1C", Data([0x81, 0, 0x1c, 0]))
    func movie(handler: String, auxiliary: Bool) -> Data {
      let descriptor = box("av01", video + (auxiliary ? box("auxi", alpha) : Data()))
      let table = box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + descriptor)
      let media = box("hdlr", Data(repeating: 0, count: 8) + Data(handler.utf8) + Data(repeating: 0, count: 12))
        + box("minf", box("stbl", table))
      return box("moov", box("trak", box("tref", box("auxl", Data([0, 0, 0, 1]))) + box("mdia", media)))
    }
    let samples = box("mdat", Data([1, 2, 3, 4, 5, 6]))
    let input = prefix + movie(handler: "pict", auxiliary: false) + samples
    let repaired = ChatImageFormat.normalized(input)
    precondition(repaired.count > input.count)
    var original = Data(repaired.prefix(input.count))
    original.replaceSubrange(prefix.count + 4..<prefix.count + 8, with: Data("moov".utf8))
    precondition(original == input, "Preserve every original sample, timing table and absolute offset")
    let added = repaired.dropFirst(input.count)
    precondition(added.range(of: Data("auxv".utf8)) != nil && added.range(of: Data("auxi".utf8)) != nil)
    precondition(ChatImageFormat.normalized(repaired) == repaired, "Normalization is idempotent across cached reads")
    let valid = prefix + movie(handler: "auxv", auxiliary: true) + samples
    precondition(ChatImageFormat.normalized(valid) == valid, "Do not rewrite already valid AVIF sequences")
    for count in 0..<input.count {
      let truncated = Data(input.prefix(count))
      precondition(ChatImageFormat.normalized(truncated) == truncated)
    }
    var oversized = input
    oversized.replaceSubrange(0..<4, with: Data([255, 255, 255, 255]))
    precondition(ChatImageFormat.normalized(oversized) == oversized)
    for input in [Data(), Data("<html>Temporary outage</html>".utf8), Data([137, 80, 78, 71])] {
      precondition(ChatImageFormat.normalized(input) == input)
    }
    print("Passed AVIF auxiliary metadata, sample preservation, idempotence, valid-input, and truncation regressions")
  }
}
