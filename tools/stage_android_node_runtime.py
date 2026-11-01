"""Stage the pinned ARMv7 Node 24 library; never alter the arm64 Git LFS file.

The release archive and extracted ELF are independently SHA-256 verified before
an atomic replacement. Run this explicitly before ARMv7/universal local builds.
"""
import argparse
import hashlib
from pathlib import Path
import tempfile
import urllib.request
from zipfile import ZipFile

ARCHIVE_URL = "https://github.com/fogtape/nodejs-mobile/releases/download/v24.21.0-0/nodejs-mobile-android-24.21.0-0.zip"
ARCHIVE_SHA256 = "e3cd29a1be03405f11dd5c857af8cd3ad13f84f1409ea648f5328f0bada5bd76"
LIBRARY_SHA256 = "15cfa70b29f83fe969c0357c133cef94cb15d99b90e53a06724b334ae915fa49"


def stage(archive: Path) -> None:
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("Android Node archive checksum mismatch")
    with ZipFile(archive) as bundle:
        library = bundle.read("bin/armeabi-v7a/libnode.so")
    if (len(library) != 79641320 or library[:6] != b"\x7fELF\x01\x01"
            or int.from_bytes(library[18:20], "little") != 40
            or hashlib.sha256(library).hexdigest() != LIBRARY_SHA256):
        raise ValueError("Android Node ARMv7 ELF checksum/header mismatch")
    target = Path(__file__).resolve().parents[1] / "packages/mgread_plugin_runtime/android/src/main/jniLibs/armeabi-v7a/libnode.so"
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".so.part")
    temporary.write_bytes(library)
    temporary.replace(target)
    print("PASS staged Node 24.21.0 ARMv7 runtime")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Use an already downloaded, verified release ZIP")
    args = parser.parse_args()
    if args.archive:
        stage(args.archive)
    else:
        with tempfile.TemporaryDirectory(prefix="mgread-node-armv7-") as directory:
            archive = Path(directory) / "node.zip"
            with urllib.request.urlopen(ARCHIVE_URL, timeout=60) as response, archive.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            stage(archive)
