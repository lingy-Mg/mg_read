"""Verify cache deletion scope and preservation of the newest usable entry."""
import unittest

from prune_flutter_ci_caches import obsolete_caches


def cache(identifier, prefix, suffix, ref="refs/heads/main"):
    return {"id": identifier, "key": prefix + suffix, "ref": ref,
            "created_at": f"2026-11-05T00:00:{identifier:02d}Z", "size_in_bytes": 100}


class CachePolicyTest(unittest.TestCase):
    def test_keeps_latest_per_platform_and_toolchain(self):
        arm = "flutter-build-linux-3.47.4-arm64-"
        win = "flutter-build-v2-Windows-X64-3.47.4-"
        entries = [cache(1, arm, "a" * 64), cache(3, arm, "b" * 64),
                   cache(2, win, "a" * 40), cache(4, win, "b" * 40),
                   cache(5, "flutter-build-linux-3.47.5-arm64-", "c" * 64)]
        self.assertEqual({c["id"] for c in obsolete_caches(entries, "refs/heads/main")}, {1, 2})

    def test_never_deletes_sdk_downloads_gradle_other_refs_or_unknown_keys(self):
        entries = [cache(1, "flutter-windows-stable-", "sdk"),
                   cache(2, "flutter-pub-windows-", "downloads"),
                   cache(3, "gradle-home-v2|", "value"),
                   cache(4, "bun-Windows-X64-", "a" * 64),
                   cache(5, "flutter-build-linux-3.47.4-arm64-", "a" * 64, "refs/heads/other"),
                   cache(6, "flutter-build-linux-3.47.4-arm64-", "b" * 64, "refs/heads/other"),
                   cache(7, "flutter-build-linux-3.47.4-arm64-", "invalid")]
        self.assertEqual(obsolete_caches(entries, "refs/heads/main"), [])

    def test_empty_and_single_entries_are_preserved(self):
        self.assertEqual(obsolete_caches([], "refs/heads/main"), [])
        self.assertEqual(obsolete_caches([cache(1, "flutter-build-v2-macOS-ARM64-3.47.4-", "a" * 40)],
                                         "refs/heads/main"), [])


if __name__ == "__main__":
    unittest.main()
