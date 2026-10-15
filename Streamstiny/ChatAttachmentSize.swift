import Foundation

enum ChatAttachmentSize {
  static func fitted(_ size: CGSize, maximum: CGSize) -> CGSize {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      return CGSize(width: maximum.height, height: maximum.height)
    }
    let scale = min(maximum.width / size.width, maximum.height / size.height)
    return CGSize(width: size.width * scale, height: size.height * scale)
  }
}
