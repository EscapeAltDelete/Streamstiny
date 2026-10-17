import AVFoundation

extension AVPlayer {
  func play(atRate rate: Float) {
    defaultRate = rate
    play()
  }
}

extension AVPlayerItem {
  convenience init(master: URL, variant: HLSVariant?, headers: [String: String]) {
    self.init(asset: AVURLAsset(
      url: variant?.playbackURL(master: master) ?? master,
      options: [AVURLAssetHTTPUserAgentKey: headers["User-Agent"] ?? PlaybackResolver.userAgent,
        "AVURLAssetHTTPHeaderFieldsKey": headers]))
    limitQuality(to: variant)
  }

  func limitQuality(to variant: HLSVariant?) {
    preferredMaximumResolution = CGSize(
      width: CGFloat(variant?.width ?? 0), height: CGFloat(variant?.height ?? 0))
    preferredPeakBitRate = variant?.bandwidth ?? 0
  }
}
