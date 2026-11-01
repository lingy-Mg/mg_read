"""Reject APKs whose packaged native ABIs or ELF headers differ from release labels."""
import argparse
from pathlib import Path
from zipfile import ZipFile

EXPECTED = {
    "arm64": {"arm64-v8a"},
    "armv7": {"armeabi-v7a"},
    "universal": {"arm64-v8a", "armeabi-v7a"},
}


def verify(path: Path, expected: set[str]) -> None:
    with ZipFile(path) as apk:
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
            abi = library.split("/")[1]
            with apk.open(library) as stream:
                header = stream.read(20)
            elf_class, machine = (1, 40) if abi == "armeabi-v7a" else (2, 183)
            if (header[:6] != b"\x7fELF" + bytes([elf_class, 1])
                    or int.from_bytes(header[18:20], "little") != machine):
                raise ValueError(f"{path}: mislabeled or invalid ELF: {library}")
    print(f"PASS {path.name}: {', '.join(sorted(expected))}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", choices=list(EXPECTED))
    names = parser.parse_args().names or list(EXPECTED)
    for name in names:
        abis = EXPECTED[name]
        verify(Path("build/android-release") / f"app-{name}.apk", abis)
