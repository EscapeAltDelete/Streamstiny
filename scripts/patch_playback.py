"""Apply checksum-verified audio fixes to the pinned KSPlayer checkout."""
import hashlib
from pathlib import Path
import stat

path = Path("build/SourcePackages/checkouts/KSPlayer/Sources/KSPlayer/MEPlayer/MEPlayerItem.swift")
original_hash = "c6225d164fb6ec37efd5a724896db1166eb574dfc7af0ca0c7b6ba911cee32ee"
patched_hash = "78c695abc74d2b2782f3fcfd80b75fce85d0e75437daaa3e8480c51db50d89db"
original = """        if index != first.trackID {
            first.isEnabled = false
            assetTracks.first { $0.mediaType == .audio && $0.trackID == index }?.isEnabled = true
        }"""
replacement = """        guard index >= 0, index != first.trackID,
              let replacement = assetTracks.first(where: { $0.mediaType == .audio && $0.trackID == index }) else {
            return
        }
        replacement.isEnabled = true
        first.isEnabled = false"""

def apply(path, original_hash, patched_hash, replacements):
    assert path.resolve().is_relative_to(Path.cwd().resolve()), "Checkout must be inside the build workspace"
    source = path.read_text(encoding="utf-8")
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == patched_hash:
        print(f"Verified fixes already applied: {path.name}")
        return
    assert digest == original_hash, "Unexpected KSPlayer source; review the pinned dependency before building"
    for original, replacement in replacements:
        assert source.count(original) == 1, "Expected exactly one source block"
        source = source.replace(original, replacement)
    assert hashlib.sha256(source.encode()).hexdigest() == patched_hash
    path.chmod(path.stat().st_mode | stat.S_IWUSR)
    path.write_text(source, encoding="utf-8", newline="\n")
    print(f"Applied verified fixes: {path.name}")


apply(path, original_hash, patched_hash, [(original, replacement)])

# Supply defined samples on the pinned player's early render returns, including
# the first callback after an audio reset and callbacks during a format change.
apply(path.with_name("AudioEnginePlayer.swift"),
      "b9d8d94e10631f90288f0e0e48bcb681d5ab43e06e1a566bb0213505a90b1e05",
      "39f62db7064f75017bbd7a23597bfe38ba9edbf6fc54dbd3c77625866579b6e0",
      [("""            if timestamp.pointee.mSampleTime == 0 {
                return noErr
            }
            self?.audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer(audioBufferList), numberOfFrames: frameCount)""",
        """            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard timestamp.pointee.mSampleTime != 0, let self else {
                AudioEnginePlayer.clearAudioBuffers(buffers)
                return noErr
            }
            self.audioPlayerShouldInputData(ioData: buffers, numberOfFrames: frameCount)"""),
       ("""    private func audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer, numberOfFrames: UInt32) {""",
        """    private static func clearAudioBuffers(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let destination = buffer.mData {
                memset(destination, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    private func audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer, numberOfFrames: UInt32) {"""),
       ("""            if sourceNodeAudioFormat != currentRender.audioFormat {
                runOnMainThread""",
        """            if sourceNodeAudioFormat != currentRender.audioFormat {
                AudioEnginePlayer.clearAudioBuffers(ioData)
                runOnMainThread""")])

# Retain the display layer and its PiP content source across resolution changes.
apply(path.with_name("MetalPlayView.swift"),
      "571c51b2f067406896c493e1cd349e8f933934c3fd797780ee54b11d49807ea7",
      "15e39dd69ff40337577551989c760c2f5d2d6071b9ee21870481632047267e08",
      [("""                displayView.removeFromSuperview()
                displayView = AVSampleBufferDisplayView()
                displayView.frame = frame
                addSubview(displayView)""",
        """                displayView.displayLayer.flush()""")])
