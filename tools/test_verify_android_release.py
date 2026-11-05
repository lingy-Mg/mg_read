"""Regression tests for the APK policy shared by local tasks and Actions."""
import hashlib
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED, ZIP_STORED

from verify_android_release import ANDROID, EXPECTED, RUNTIME, verify


def fixture(path, abis, *, extra=None, omit=None, bad_marker=False, stored=False):
    assets = {"cli.js": b"export {};", "desktop-runtime.js": b"export {};", "package.json": b'{"type":"module"}'}
    if omit:
        assets.pop(omit)
    digest = hashlib.sha256()
    for name, value in sorted(assets.items()):
        digest.update(name.encode() + b"\0" + value + b"\0")
    marker = "0.5.0-test-" + ("0" * 64 if bad_marker else digest.hexdigest()) + "\n"
    with ZipFile(path, "w", compression=ZIP_DEFLATED) as apk:
        apk.writestr(ANDROID + "runtime-version.txt", marker)
        for name, value in assets.items():
            apk.writestr(ANDROID + "dist/" + name, value)
        for abi in abis:
            header = bytearray(20)
            header[:6] = b"\x7fELF" + bytes([1 if abi == "armeabi-v7a" else 2, 1])
            header[18:20] = (40 if abi == "armeabi-v7a" else 183).to_bytes(2, "little")
            libs = ["libflutter.so", "libapp.so", "libmgread_native_runtime.so", "libnode.so", "libmgread_node_bridge.so", "libc++_shared.so"]
            if abi == "arm64-v8a":
                libs.append("libjavet-node-android.v.6.0.1.so")
            for name in libs:
                apk.writestr(f"lib/{abi}/{name}", header, compress_type=ZIP_STORED if stored else ZIP_DEFLATED)
        if extra:
            apk.writestr(extra, b"unwanted")


class ReleasePolicyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mgread-apk-policy-")
        self.addCleanup(self.temporary.cleanup)
        self.apk = Path(self.temporary.name) / "fixture.apk"

    def test_all_release_abis_and_both_js_hosts(self):
        for abis in EXPECTED.values():
            with self.subTest(abis=abis):
                fixture(self.apk, abis)
                self.assertEqual(verify(self.apk, abis)["runtimeFiles"], 4)

    def test_rejects_foreign_and_development_payloads(self):
        for unwanted in [RUNTIME + "macos-arm64/node/MgReadBun", RUNTIME + "windows-x64/node/MgReadNode.exe",
                         ANDROID + "dist/cli.d.ts", ANDROID + "dist/cli.js.map",
                         ANDROID + "dist/windows-release/cli.js", ANDROID + "node_modules/npm/index.js"]:
            with self.subTest(unwanted=unwanted):
                fixture(self.apk, EXPECTED["arm64"], extra=unwanted)
                with self.assertRaises(ValueError):
                    verify(self.apk, EXPECTED["arm64"])

    def test_rejects_stale_content_marker(self):
        fixture(self.apk, EXPECTED["arm64"], bad_marker=True)
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            verify(self.apk, EXPECTED["arm64"])

    def test_keeps_both_host_entries(self):
        for entry in ["cli.js", "desktop-runtime.js"]:
            fixture(self.apk, EXPECTED["arm64"], omit=entry)
            with self.assertRaisesRegex(ValueError, "Missing Android Runtime entry"):
                verify(self.apk, EXPECTED["arm64"])

    def test_rejects_uncompressed_native_libraries(self):
        fixture(self.apk, EXPECTED["arm64"], stored=True)
        with self.assertRaisesRegex(ValueError, "Uncompressed native library"):
            verify(self.apk, EXPECTED["arm64"])


if __name__ == "__main__":
    unittest.main()
