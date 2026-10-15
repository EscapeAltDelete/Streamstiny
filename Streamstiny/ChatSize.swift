import Foundation

enum ChatSize {
  static func extent(size: CGSize, fraction: Double, landscape: Bool) -> CGFloat {
    let available = max(0, landscape ? size.width : size.height)
    if !landscape {
      // Fit a 16:9 video above chat; keep room for chat when the keyboard opens.
      return available - min(max(0, size.width) * 9 / 16, available * 0.5)
    }
    let minimum = min(220, available * 0.3)
    let maximum = max(minimum, min(available * 0.65, available - 240))
    let fraction = fraction.isFinite ? fraction : 0.36
    return min(maximum, max(minimum, available * fraction))
  }
}
