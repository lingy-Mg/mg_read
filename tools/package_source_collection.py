#!/usr/bin/env python3
"""Build a deterministic MgRead collection from built Node source artifacts.

Only packages with package.json, mgread metadata, and pack:plugin are eligible.
The script never searches for arbitrary old artifacts: it requires the exact
filename derived from the package's id and version in that package's artifacts
directory. --artifact-root supports fixtures/local prebuilt outputs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
import zlib
import zipfile
from pathlib import Path, PurePosixPath

MAX_PLUGIN_BYTES = 32 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_PLUGINS = 256
ZIP_TIME = (2020, 1, 1, 0, 0, 0)
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SAFE_VERSION = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")


def eligible_packages(sources: Path) -> list[tuple[Path, dict]]:
    found = []
    if not sources.is_dir():
        raise ValueError(f"Source directory does not exist: {sources}")
    for package_path in sorted(sources.glob("*/package.json"), key=lambda p: p.parent.name):
        try:
            package = json.loads(package_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"Invalid package metadata {package_path}: {exc}") from exc
        meta = package.get("mgread")
        scripts = package.get("scripts", {})
        if not isinstance(meta, dict):
            continue
        engine = meta.get("engine", "node")
        if engine == "native":
            continue
        if engine != "node":
            raise ValueError(f"Unsupported mgread.engine {engine!r} in {package_path}")
        if not isinstance(scripts, dict) or "pack:plugin" not in scripts:
            raise ValueError(f"Missing scripts.pack:plugin in {package_path}")
        package_mode = meta.get("packageMode", "single-file")
        if package_mode not in ("single-file", "archive"):
            raise ValueError(f"Unsupported mgread.packageMode {package_mode!r} in {package_path}")
        plugin_id, name, version = meta.get("id"), meta.get("displayName"), package.get("version")
        if not isinstance(plugin_id, str) or not SAFE_ID.fullmatch(plugin_id):
            raise ValueError(f"Unsafe or missing mgread.id in {package_path}")
        if not isinstance(name, str) or not name.strip() or len(name) > 200:
            raise ValueError(f"Missing mgread.displayName in {package_path}")
        if not isinstance(version, str) or not SAFE_VERSION.fullmatch(version):
            raise ValueError(f"Unsafe or missing package.version in {package_path}")
        found.append((package_path.parent, package))
    return found


def build_collection(sources: Path, output: Path, artifact_root: Path | None = None) -> list[dict]:
    packages = eligible_packages(sources)
    if not packages:
        raise ValueError("No eligible Node source packages were found")
    if len(packages) > MAX_PLUGINS:
        raise ValueError(f"Collection exceeds {MAX_PLUGINS} Node source packages")
    ids: set[str] = set()
    filenames: set[str] = set()
    entries: list[dict] = []
    payloads: list[tuple[str, bytes]] = []
    total = 0
    for project, package in packages:
        meta = package["mgread"]
        plugin_id, version = meta["id"], package["version"]
        if plugin_id in ids:
            raise ValueError(f"Duplicate source id: {plugin_id}")
        ids.add(plugin_id)
        package_mode = meta.get("packageMode", "single-file")
        filename = f"{plugin_id}-{version}.mgplugin.js" if package_mode == "single-file" else f"{plugin_id}-{version}.mgplugin"
        if filename in filenames:
            raise ValueError(f"Duplicate artifact filename: {filename}")
        filenames.add(filename)
        artifact_dir = (artifact_root / project.name / "artifacts") if artifact_root else (project / "artifacts")
        artifact = artifact_dir / filename
        # Reject symlinks and path escapes even when using caller-provided files.
        if artifact.is_symlink() or not artifact.is_file():
            raise ValueError(f"Missing regular artifact file: {artifact}")
        resolved_dir, resolved_artifact = artifact_dir.resolve(), artifact.resolve()
        if resolved_dir not in resolved_artifact.parents:
            raise ValueError(f"Artifact path escapes its source directory: {artifact}")
        size = artifact.stat().st_size
        if size <= 0:
            raise ValueError(f"Artifact is empty: {artifact}")
        if size > MAX_PLUGIN_BYTES:
            raise ValueError(f"Artifact exceeds 32 MiB: {artifact} ({size} bytes)")
        total += size
        if total > MAX_TOTAL_BYTES:
            raise ValueError(f"Combined raw artifacts exceed 512 MiB ({total} bytes)")
        data = artifact.read_bytes()
        relpath = PurePosixPath("plugins", filename).as_posix()
        entries.append({"id": plugin_id, "name": meta["displayName"], "version": version,
                        "format": "singleFile" if package_mode == "single-file" else "archive",
                        "path": relpath, "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest()})
        payloads.append((relpath, data))

    order = sorted(range(len(entries)), key=lambda i: (entries[i]["id"], entries[i]["path"]))
    entries = [entries[i] for i in order]
    payloads = [payloads[i] for i in order]
    manifest = {"format": "mgread-source-collection", "schemaVersion": 1, "plugins": entries}
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(manifest_bytes) > MAX_MANIFEST_BYTES:
        raise ValueError("Collection manifest exceeds 1 MiB")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, strict_timestamps=True) as archive:
        _write_entry(archive, "manifest.json", manifest_bytes)
        for path, data in payloads:
            _write_entry(archive, path, data)
    if output.stat().st_size > MAX_ARCHIVE_BYTES:
        output.unlink()
        raise ValueError("Collection ZIP exceeds 512 MiB")
    return entries


def build_online_catalog(sources: Path, output_dir: Path, release_base_url: str,
                         artifact_root: Path | None = None) -> list[dict]:
    """Create a static GitHub-hosted catalog and independently downloadable plugins."""
    packages = eligible_packages(sources)
    if not packages:
        raise ValueError("No eligible Node source packages were found")
    if len(packages) > MAX_PLUGINS:
        raise ValueError(f"Online catalog exceeds {MAX_PLUGINS} Node source packages")
    base_url = release_base_url.rstrip("/")
    if not base_url.startswith("https://"):
        raise ValueError("Online catalog release base URL must use HTTPS")

    entries: list[dict] = []
    ids: set[str] = set()
    total = 0
    plugins_dir = output_dir / "plugins"
    plugins_dir.mkdir(parents=True, exist_ok=True)
    for project, package in packages:
        meta = package["mgread"]
        plugin_id, version = meta["id"], package["version"]
        if plugin_id in ids:
            raise ValueError(f"Duplicate source id: {plugin_id}")
        ids.add(plugin_id)
        if meta.get("packageMode", "single-file") != "single-file":
            # The online repository serves standalone JS files. Archives remain
            # available through the existing offline collection download.
            continue
        filename = f"{plugin_id}.mgplugin.js"
        artifact_dir = (artifact_root / project.name / "artifacts") if artifact_root else (project / "artifacts")
        artifact = artifact_dir / f"{plugin_id}-{version}.mgplugin.js"
        if artifact.is_symlink() or not artifact.is_file():
            raise ValueError(f"Missing regular artifact file: {artifact}")
        if artifact_dir.resolve() not in artifact.resolve().parents:
            raise ValueError(f"Artifact path escapes its source directory: {artifact}")
        data = artifact.read_bytes()
        if not data.startswith(b"// @mgread-plugin-v1 "):
            raise ValueError(f"Artifact is missing the MgRead online plugin tag: {artifact}")
        if not data or len(data) > MAX_PLUGIN_BYTES:
            raise ValueError(f"Artifact is empty or exceeds 32 MiB: {artifact}")
        total += len(data)
        if total > MAX_TOTAL_BYTES:
            raise ValueError(f"Online catalog artifacts exceed 512 MiB ({total} bytes)")
        (plugins_dir / filename).write_bytes(data)
        entries.append({
            "id": plugin_id,
            "name": meta["displayName"],
            "version": version,
            "format": "singleFile",
            "path": f"plugins/{filename}",
            "url": f"{base_url}/{filename}",
            "bytes": len(data),
            "crc32": f"{zlib.crc32(data) & 0xffffffff:08x}",
            "sha256": hashlib.sha256(data).hexdigest(),
        })
    if not entries:
        raise ValueError("No single-file Node sources are available for the online catalog")
    entries.sort(key=lambda item: item["id"])
    manifest = {"format": "mgread-online-plugin-catalog", "schemaVersion": 1, "plugins": entries}
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(manifest_bytes) > MAX_MANIFEST_BYTES:
        raise ValueError("Online catalog manifest exceeds 1 MiB")
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "catalog.json").write_bytes(manifest_bytes)
    return entries


def _write_entry(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, date_time=ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    info.flag_bits |= 0x800
    archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, required=True, help="plugins/sources directory")
    parser.add_argument("--output", type=Path, help="output .mgplugins ZIP")
    parser.add_argument("--artifact-root", type=Path, help="optional root containing <source>/artifacts")
    parser.add_argument("--online-output", type=Path, help="write standalone plugins and catalog.json for a static repository")
    parser.add_argument("--release-base-url", help="HTTPS GitHub Release download URL used by --online-output")
    parser.add_argument("--list-packages", action="store_true", help="print eligible package directories")
    args = parser.parse_args(argv)
    try:
        if args.list_packages:
            for project, _ in eligible_packages(args.sources):
                print(project.as_posix())
            return 0
        if args.output is None and args.online_output is None:
            parser.error("--output or --online-output is required unless --list-packages is used")
        if args.output is not None:
            entries = build_collection(args.sources, args.output, args.artifact_root)
            print(f"Created {args.output} with {len(entries)} plugins")
        if args.online_output is not None:
            if args.release_base_url is None:
                parser.error("--release-base-url is required with --online-output")
            online_entries = build_online_catalog(args.sources, args.online_output, args.release_base_url, args.artifact_root)
            print(f"Created online catalog in {args.online_output} with {len(online_entries)} standalone plugins")
        return 0
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"source collection: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
