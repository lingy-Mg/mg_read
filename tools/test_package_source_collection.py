"""Direct tests for deterministic source collection packaging."""

import hashlib
import importlib.util
import json
import shutil
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("package_source_collection.py")
SPEC = importlib.util.spec_from_file_location("package_source_collection", MODULE_PATH)
pack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pack)


class PackageSourceCollectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.sources = self.root / "sources"
        self.sources.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def add_plugin(self, folder, plugin_id, name=None, payload=b"bundle", mode="single-file"):
        project = self.sources / folder
        project.mkdir()
        package = {"version": "1.2.3", "scripts": {"pack:plugin": "node pack"},
                   "mgread": {"id": plugin_id, "displayName": name or folder,
                              "packageMode": mode}}
        (project / "package.json").write_text(json.dumps(package), encoding="utf-8")
        artifact_dir = project / "artifacts"
        artifact_dir.mkdir()
        extension = ".mgplugin.js" if mode == "single-file" else ".mgplugin"
        (artifact_dir / f"{plugin_id}-1.2.3{extension}").write_bytes(payload)
        return project

    def test_deterministic_archive_manifest_and_hashes(self):
        self.add_plugin("zeta", "org.mgread.zeta", payload=b"z" * 1024)
        self.add_plugin("alpha", "org.mgread.alpha", payload=b"alpha")
        first, second = self.root / "one.mgplugins", self.root / "two.mgplugins"
        pack.build_collection(self.sources, first)
        pack.build_collection(self.sources, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(archive.namelist(), ["manifest.json", "plugins/org.mgread.alpha-1.2.3.mgplugin.js",
                                                   "plugins/org.mgread.zeta-1.2.3.mgplugin.js"])
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(list(manifest), ["format", "schemaVersion", "plugins"])
            self.assertEqual(manifest["format"], "mgread-source-collection")
            self.assertEqual(manifest["schemaVersion"], 1)
            self.assertEqual([p["id"] for p in manifest["plugins"]],
                             ["org.mgread.alpha", "org.mgread.zeta"])
            for entry in manifest["plugins"]:
                data = archive.read(entry["path"])
                self.assertEqual(entry["bytes"], len(data))
                self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
                self.assertEqual(entry["format"], "singleFile")

    def test_missing_or_modified_source_artifact_is_rejected_or_rehashed(self):
        project = self.add_plugin("alpha", "org.mgread.alpha")
        artifact = project / "artifacts/org.mgread.alpha-1.2.3.mgplugin.js"
        artifact.unlink()
        with self.assertRaisesRegex(ValueError, "Missing regular artifact"):
            pack.build_collection(self.sources, self.root / "missing.mgplugins")
        artifact.write_bytes(b"original")
        pack.build_collection(self.sources, self.root / "before.mgplugins")
        artifact.write_bytes(b"tampered")
        pack.build_collection(self.sources, self.root / "after.mgplugins")
        with zipfile.ZipFile(self.root / "after.mgplugins") as archive:
            manifest = json.loads(archive.read("manifest.json"))
            entry = manifest["plugins"][0]
            payload = archive.read(entry["path"])
            self.assertEqual(entry["sha256"], hashlib.sha256(payload).hexdigest())
            self.assertEqual(payload, b"tampered")
            self.assertNotEqual(entry["sha256"], hashlib.sha256(b"original").hexdigest())

    def test_native_and_legacy_directories_without_package_json_are_excluded(self):
        self.add_plugin("supported", "org.mgread.supported")
        native = self.sources / "aisishuwu-native"
        native.mkdir()
        (native / "Cargo.toml").write_text("[package]", encoding="utf-8")
        declared_native = self.add_plugin("declared-native", "org.mgread.declared-native")
        native_package = declared_native / "package.json"
        native_metadata = json.loads(native_package.read_text(encoding="utf-8"))
        native_metadata["mgread"]["engine"] = "native"
        native_package.write_text(json.dumps(native_metadata), encoding="utf-8")
        legacy = self.sources / "old-source"
        legacy.mkdir()
        self.assertEqual([p.name for p, _ in pack.eligible_packages(self.sources)], ["supported"])
        pack.build_collection(self.sources, self.root / "result.mgplugins")
        with zipfile.ZipFile(self.root / "result.mgplugins") as archive:
            self.assertEqual(len(json.loads(archive.read("manifest.json"))["plugins"]), 1)

    def test_archive_artifact_is_included_with_archive_format(self):
        self.add_plugin("archive", "org.mgread.archive", mode="archive", payload=b"archive-bytes")
        pack.build_collection(self.sources, self.root / "archive.mgplugins")
        with zipfile.ZipFile(self.root / "archive.mgplugins") as archive:
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["plugins"][0]["format"], "archive")
            self.assertEqual(manifest["plugins"][0]["path"], "plugins/org.mgread.archive-1.2.3.mgplugin")

    def test_online_catalog_publishes_tagged_standalone_plugins_with_integrity_metadata(self):
        payload = b"// @mgread-plugin-v1 eyJ2ZXJzaW9uIjoiMS4yLjMifQ==\nexport default {};"
        self.add_plugin("alpha", "org.mgread.alpha", payload=payload)
        self.add_plugin("archived", "org.mgread.archived", mode="archive", payload=b"archive")
        output = self.root / "online"

        entries = pack.build_online_catalog(
            self.sources,
            output,
            "https://github.com/example/mg_read/releases/download/source-catalog",
        )

        self.assertEqual([entry["id"] for entry in entries], ["org.mgread.alpha"])
        self.assertEqual((output / "plugins/org.mgread.alpha.mgplugin.js").read_bytes(), payload)
        manifest = json.loads((output / "catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["format"], "mgread-online-plugin-catalog")
        self.assertEqual(manifest["schemaVersion"], 1)
        entry = manifest["plugins"][0]
        self.assertEqual(entry["url"], "https://github.com/example/mg_read/releases/download/source-catalog/org.mgread.alpha.mgplugin.js")
        self.assertEqual(entry["bytes"], len(payload))
        self.assertEqual(entry["crc32"], f"{zlib.crc32(payload) & 0xffffffff:08x}")
        self.assertEqual(entry["sha256"], hashlib.sha256(payload).hexdigest())

    def test_online_catalog_rejects_artifacts_without_plugin_tag(self):
        self.add_plugin("alpha", "org.mgread.alpha", payload=b"export default {};")

        with self.assertRaisesRegex(ValueError, "missing the MgRead online plugin tag"):
            pack.build_online_catalog(
                self.sources,
                self.root / "online",
                "https://github.com/example/mg_read/releases/download/source-catalog",
            )

    def test_incomplete_or_unsupported_node_packages_fail_closed(self):
        project = self.add_plugin("incomplete", "org.mgread.incomplete")
        package_file = project / "package.json"
        package = json.loads(package_file.read_text(encoding="utf-8"))
        del package["scripts"]["pack:plugin"]
        package_file.write_text(json.dumps(package), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Missing scripts.pack:plugin"):
            pack.eligible_packages(self.sources)
        package["scripts"]["pack:plugin"] = "node pack"
        package["mgread"]["packageMode"] = "native"
        package_file.write_text(json.dumps(package), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Unsupported mgread.packageMode"):
            pack.eligible_packages(self.sources)

    def test_duplicate_ids_and_unsafe_ids_are_rejected(self):
        self.add_plugin("one", "org.mgread.duplicate")
        self.add_plugin("two", "org.mgread.duplicate")
        with self.assertRaisesRegex(ValueError, "Duplicate source id"):
            pack.build_collection(self.sources, self.root / "duplicate.mgplugins")
        for path in self.sources.iterdir():
            shutil.rmtree(path)
        self.add_plugin("unsafe", "../escape")
        with self.assertRaisesRegex(ValueError, "Unsafe or missing mgread.id"):
            pack.eligible_packages(self.sources)

    def test_individual_and_total_limits(self):
        project = self.add_plugin("large", "org.mgread.large", payload=b"x" * (pack.MAX_PLUGIN_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "exceeds 32 MiB"):
            pack.build_collection(self.sources, self.root / "large.mgplugins")
        (project / "artifacts/org.mgread.large-1.2.3.mgplugin.js").write_bytes(b"x")
        self.add_plugin("second", "org.mgread.second", payload=b"y")
        original_limit = pack.MAX_TOTAL_BYTES
        try:
            pack.MAX_TOTAL_BYTES = 1
            with self.assertRaisesRegex(ValueError, "exceed 512 MiB"):
                pack.build_collection(self.sources, self.root / "total.mgplugins")
        finally:
            pack.MAX_TOTAL_BYTES = original_limit

        original_count_limit = pack.MAX_PLUGINS
        try:
            pack.MAX_PLUGINS = 1
            with self.assertRaisesRegex(ValueError, "exceeds 1 Node source packages"):
                pack.build_collection(self.sources, self.root / "count.mgplugins")
        finally:
            pack.MAX_PLUGINS = original_count_limit

        original_archive_limit = pack.MAX_ARCHIVE_BYTES
        try:
            pack.MAX_ARCHIVE_BYTES = 1
            output = self.root / "archive-limit.mgplugins"
            with self.assertRaisesRegex(ValueError, "ZIP exceeds 512 MiB"):
                pack.build_collection(self.sources, output)
            self.assertFalse(output.exists())
        finally:
            pack.MAX_ARCHIVE_BYTES = original_archive_limit


if __name__ == "__main__":
    unittest.main()
