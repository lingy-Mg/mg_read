"""Inspect delivered native packages without running Node or source code.

Only explicitly supplied build directories/archives are enumerated. ELF checks
establish alignment of our libraries, not full 16 KiB device compatibility.
"""
from __future__ import annotations
import argparse, hashlib, json, pathlib, struct, zipfile


def digest(data):
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def elf(data):
    assert data[:6] == b"\x7fELF\x02\x01", "Expected ELF64 little-endian"
    machine = struct.unpack_from("<H", data, 18)[0]
    offset = struct.unpack_from("<Q", data, 32)[0]
    width, count = struct.unpack_from("<HH", data, 54)
    align = [struct.unpack_from("<Q", data, offset + i * width + 48)[0]
        for i in range(count) if struct.unpack_from("<I", data, offset + i * width)[0] == 1]
    assert align and min(align) >= 16384, "Native ELF requires 16 KiB alignment"
    return {"machine": machine, "loadSegmentAlignments": align}


def forbidden(name):
    value = name.lower().replace("\\", "/")
    return "assets/runtime/" in value or pathlib.PurePosixPath(value).name.startswith(("node.exe", "libnode", "libjavet"))


def run(args):
    report = {"status": "passed", "apks": []}
    plugin = pathlib.Path(args.plugin)
    raw = plugin.read_bytes()
    with zipfile.ZipFile(plugin) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["engine"] == "native" and manifest["abi"] == 1
        targets = {}
        for target, entry in manifest["targets"].items():
            data = archive.read(entry["path"])
            assert digest(data)["sha256"] == entry["sha256"]
            targets[target] = digest(data)
            if target.startswith("android-"): targets[target].update(elf(data))
        report["plugin"] = {**digest(raw), "targets": targets}
    if args.windows:
        root = pathlib.Path(args.windows)
        files = [p for p in root.rglob("*") if p.is_file()]
        rejected = [str(p.relative_to(root)) for p in files if forbidden(str(p.relative_to(root)))]
        assert not rejected, rejected
        host = root / "native/mgread-native-host.exe"
        assert host.is_file() and (root / "mg_read.exe").is_file()
        report["windows"] = {"fileCount": len(files), "bytes": sum(p.stat().st_size for p in files),
            "host": digest(host.read_bytes()), "forbiddenEntries": rejected}
    for item in args.apk:
        path = pathlib.Path(item)
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            rejected = [name for name in names if forbidden(name)]
            assert not rejected, rejected
            libs = {name: {**digest(archive.read(name)), **elf(archive.read(name))} for name in names
                if name.startswith("lib/") and name.endswith("/libmgread_native_runtime.so")}
            assert libs, "APK lacks native Rust host"
            if args.require_android_abis:
                expected = set(args.require_android_abis.split(","))
                actual = {name.split("/")[1] for name in libs}
                assert actual == expected, f"APK host ABI mismatch: {actual} != {expected}"
                for abi in expected:
                    assert f"lib/{abi}/libflutter.so" in names, f"APK lacks Flutter for {abi}"
                    if any(name.endswith("/libapp.so") for name in names):
                        assert f"lib/{abi}/libapp.so" in names, f"APK lacks AOT Dart for {abi}"
            for name in names:
                if name.endswith(".dex"):
                    data = archive.read(name)
                    for symbol in (b"Lcom/caoccao/javet/", b"Lcom/mgread/mgread_plugin_runtime/AndroidNodeProcessService;",
                                   b"Lcom/mgread/mgread_plugin_runtime/AndroidRuntimeHost;"):
                        assert symbol not in data, "Legacy Runtime class in native APK"
            report["apks"].append({"name": path.name, **digest(path.read_bytes()), "nativeHosts": libs,
                "forbiddenEntries": rejected, "legacyDexClassesAbsent": True})
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf8")
    print(json.dumps({"status": "passed", "output": str(output)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--windows")
    parser.add_argument("--apk", action="append", default=[])
    parser.add_argument("--plugin", required=True)
    parser.add_argument("--require-android-abis", help="Exact comma-separated host ABIs required in every APK")
    parser.add_argument("--output", required=True)
    run(parser.parse_args())
