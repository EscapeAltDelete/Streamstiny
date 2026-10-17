import AVFoundation
import CoreVideo
import Foundation

enum NativePlayerTests {
  @MainActor static func run() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let master = directory.appendingPathComponent("master.m3u8")
    let rendition = directory.appendingPathComponent("1080.m3u8")
    let selected = HLSVariant(url: rendition, width: 1920, height: 1080, bandwidth: 5000000, frameRate: 60, externalMedia: false)
    let exact = AVPlayerItem(master: master, variant: selected, headers: [:])
    precondition((exact.asset as? AVURLAsset)?.url == rendition, "Explicit muxed quality must select its rendition")
    let audioGroup = HLSVariant(url: rendition, width: 1920, height: 1080, bandwidth: 5000000, frameRate: 60, externalMedia: true)
    let capped = AVPlayerItem(master: master, variant: audioGroup, headers: [:])
    precondition((capped.asset as? AVURLAsset)?.url == master, "Do not lose alternate audio")
    precondition(capped.preferredPeakBitRate == 5000000 && capped.preferredMaximumResolution.height == 1080)
    capped.limitQuality(to: nil)
    precondition(capped.preferredPeakBitRate == 0 && capped.preferredMaximumResolution == .zero)

    let video = directory.appendingPathComponent("clock.mov")
    let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    writer.add(input)
    precondition(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    CVPixelBufferLockBaseAddress(buffer!, [])
    memset(CVPixelBufferGetBaseAddress(buffer!)!, 0, CVPixelBufferGetDataSize(buffer!))
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    for frame in 0..<120 {
      while !input.isReadyForMoreMediaData {
        precondition(writer.status == .writing)
        try await Task.sleep(for: .milliseconds(2))
      }
      precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    precondition(writer.status == .completed)

    let player = AVPlayer(url: video)
    player.play(atRate: 2)
    for _ in 0..<100 {
      if player.timeControlStatus == .playing, player.currentTime().seconds > 0 { break }
      precondition(player.currentItem?.status != .failed)
      try await Task.sleep(for: .milliseconds(50))
    }
    precondition(player.automaticallyWaitsToMinimizeStalling, "2× must retain native buffering")
    precondition(player.timeControlStatus == .playing && player.rate == 2)
    for rate in [Float(2), Float(1)] {
      player.play(atRate: rate)
      let start = player.currentTime().seconds
      let clock = ProcessInfo.processInfo.systemUptime
      try await Task.sleep(for: .milliseconds(300))
      let measured = (player.currentTime().seconds - start) / (ProcessInfo.processInfo.systemUptime - clock)
      precondition(abs(measured - Double(rate)) < 0.3, "Media clock must advance at \(rate)×, got \(measured)")
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
    print("Passed native quality routing, alternate audio, buffering policy, and measured 2×/1× media-clock regressions")
  }
}
