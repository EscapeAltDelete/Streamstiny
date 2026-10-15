"""Validate package metadata and the ARM64 Mach-O before uploading an IPA."""
import plistlib
import struct
import sys
import zipfile


def validate(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, "Corrupt ZIP entry"
        root = "Payload/Streamstiny.app/"
        info = plistlib.loads(archive.read(root + "Info.plist"))
        assert info["CFBundleIdentifier"] == "gg.streamstiny.app"
        assert info["CFBundleExecutable"] == "Streamstiny"
        assert info["MinimumOSVersion"] == "17.0"
        binary = archive.read(root + info["CFBundleExecutable"])
        magic, cpu = struct.unpack_from("<II", binary)
        assert magic == 0xFEEDFACF, "Expected 64-bit thin Mach-O"
        assert cpu == 0x0100000C, "Expected ARM64 executable"
        offset = 32
        signature = None
        for _ in range(struct.unpack_from("<I", binary, 16)[0]):
            command, size = struct.unpack_from("<II", binary, offset)
            assert size >= 8, "Invalid Mach-O load command"
            if command == 0x1D:
                start, length = struct.unpack_from("<II", binary, offset + 8)
                signature = binary[start:start + length]
            offset += size
        assert signature is not None, "Missing code signature"
        magic, length, count = struct.unpack_from(">III", signature)
        assert magic == 0xFADE0CC0 and length <= len(signature), "Invalid signature container"
        entitlements = None
        for index in range(count):
            slot, start = struct.unpack_from(">II", signature, 12 + index * 8)
            if slot == 5:
                magic, size = struct.unpack_from(">II", signature, start)
                assert magic == 0xFADE7171, "Invalid entitlements blob"
                entitlements = plistlib.loads(signature[start + 8:start + size])
        assert entitlements is not None, "Missing app entitlements"
        identity = "TROLLTROLL.gg.streamstiny.app"
        assert entitlements.get("application-identifier") == identity
        assert entitlements.get("keychain-access-groups") == [identity], "Missing app Keychain access"
        assert root + "_CodeSignature/CodeResources" in archive.namelist()
    print("Validated Streamstiny IPA: ARM64, iOS 17.0, signature resources, app Keychain entitlements, correct bundle.")


if __name__ == "__main__":
    validate(sys.argv[1])
