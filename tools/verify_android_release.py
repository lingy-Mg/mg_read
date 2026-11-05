"""Validate local/CI APK ABI, executable assets and download-size policy.

Reads signed APKs without rewriting them. Rejects desktop payloads, developer
metadata and stale asset fingerprints, and preserves both Android JS hosts.
"""
import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

EXPECTED = {
    "arm64": {"arm64-v8a"},
    "armv7": {"armeabi-v7a"},
    "universal": {"arm64-v8a", "armeabi-v7a"},
}
RUNTIME = "assets/flutter_assets/packages/mgread_plugin_runtime/assets/runtime/"
ANDROID = RUNTIME + "android/"


def verify_assets(apk: ZipFile) -> int:
    names = [name for name in apk.namelist() if not name.endswith("/")]
    runtime = [name for name in names if name.startswith(RUNTIME)]
    for name in runtime:
        if not name.startswith(ANDROID):
            raise ValueError(f"Desktop Runtime must not enter Android APK: {name}")
        if name.endswith((".map", ".d.ts")) or "/windows-release/" in name or "/node_modules/" in name:
            raise ValueError(f"Development-only Runtime asset: {name}")
    for entry in ("runtime-version.txt", "dist/cli.js", "dist/desktop-runtime.js", "dist/package.json"):
        if ANDROID + entry not in names:
            raise ValueError(f"Missing Android Runtime entry: {entry}")
    if json.loads(apk.read(ANDROID + "dist/package.json")) != {"type": "module"}:
        raise ValueError("Android process Runtime must declare ESM")
    digest = hashlib.sha256()
    prefix = ANDROID + "dist/"
    for name in sorted(name for name in runtime if name.startswith(prefix)):
        digest.update(name[len(prefix):].encode())
        digest.update(b"\0")
        digest.update(apk.read(name))
        digest.update(b"\0")
    marker = apk.read(ANDROID + "runtime-version.txt").decode().strip()
    if not marker.endswith("-" + digest.hexdigest()):
        raise ValueError("Android Runtime content fingerprint is stale")
    return len(runtime)


def verify(path: Path, expected: set[str]) -> dict:
    with ZipFile(path) as apk:
        runtime_files = verify_assets(apk)
        libraries = {p for p in apk.namelist() if p.startswith("lib/") and p.endswith(".so")}
        actual = {p.split("/")[1] for p in libraries}
        if actual != expected:
            raise ValueError(f"{path}: expected {expected}, got {actual}")
        for abi in expected:
            for library in ("libflutter.so", "libapp.so", "libmgread_native_runtime.so", "libnode.so", "libmgread_node_bridge.so", "libc++_shared.so"):
                if f"lib/{abi}/{library}" not in libraries:
                    raise ValueError(f"{path}: missing {abi}/{library}")
            if abi == "arm64-v8a" and not any(p.startswith(f"lib/{abi}/libjavet") for p in libraries):
                raise ValueError(f"{path}: missing ARM64 Javet")
        for library in libraries:
            if apk.getinfo(library).compress_type != ZIP_DEFLATED:
                raise ValueError(f"Uncompressed native library increases APK download size: {library}")
            abi = library.split("/")[1]
            with apk.open(library) as stream:
                header = stream.read(20)
            elf_class, machine = (1, 40) if abi == "armeabi-v7a" else (2, 183)
            if (header[:6] != b"\x7fELF" + bytes([elf_class, 1])
                    or int.from_bytes(header[18:20], "little") != machine):
                raise ValueError(f"{path}: mislabeled or invalid ELF: {library}")
        files = [info for info in apk.infolist() if not info.is_dir()]
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1048576), b""):
                digest.update(chunk)
        result = {"path": str(path), "abis": sorted(expected), "bytes": path.stat().st_size,
                  "files": len(files), "runtimeFiles": runtime_files, "sha256": digest.hexdigest()}
    print(f"PASS {path.name}: {', '.join(sorted(expected))}; {result['bytes'] / 1048576:.2f} MiB; Runtime files={runtime_files}")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", choices=list(EXPECTED))
    parser.add_argument("--apk", type=Path, help="Verify a local APK using exactly one ABI label")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    names = args.names or list(EXPECTED)
    if args.apk and len(names) != 1:
        parser.error("--apk requires exactly one of arm64/armv7/universal")
    results = []
    for name in names:
        abis = EXPECTED[name]
        results.append(verify(args.apk or Path("build/android-release") / f"app-{name}.apk", abis))
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({"schemaVersion": 1, "apks": results}, indent=2), encoding="utf-8")
