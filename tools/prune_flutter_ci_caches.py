"""Keep the newest Flutter compilation cache per platform on the current ref.

Owns only the two compilation-cache key families below, never SDK/download,
Gradle, other branches, or release artifacts. Lists all pages before deleting;
dry-run is the default. CI supplies its repository/ref and scoped Actions token.
"""
import argparse
import json
import os
import re
import subprocess


PATTERNS = (
    re.compile(r"^(flutter-build-linux-[\d.]+-(?:arm64|armv7|universal)-)[0-9a-f]{64}$"),
    re.compile(r"^(flutter-build-v2-(?:Windows|macOS)-(?:X64|ARM64)-[\d.]+-)[0-9a-f]{40}$"),
)


def obsolete_caches(caches, ref):
    groups = {}
    for cache in caches:
        if cache["ref"] != ref:
            continue
        match = next((m for pattern in PATTERNS if (m := pattern.fullmatch(cache["key"]))), None)
        if match:
            groups.setdefault(match[1], []).append(cache)
    return [cache for group in groups.values()
            for cache in sorted(group, key=lambda c: (c["created_at"], c["id"]), reverse=True)[1:]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    ref = os.environ["GITHUB_REF"]
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository) or not ref.startswith("refs/heads/"):
        raise ValueError("Expected a repository and branch ref")
    pages = json.loads(subprocess.check_output([
        "gh", "api", "--paginate", "--slurp", f"repos/{repository}/actions/caches?per_page=100",
    ], text=True, encoding="utf-8"))
    plan = obsolete_caches([cache for page in pages for cache in page["actions_caches"]], ref)
    for cache in plan:
        print(f"{'DELETE' if args.apply else 'DRY RUN'} {cache['id']} {cache['key']}")
        if args.apply:
            subprocess.run(["gh", "api", "--method", "DELETE",
                            f"repos/{repository}/actions/caches/{cache['id']}"], check=True)
    print(json.dumps({"deleted" if args.apply else "candidates": len(plan),
                      "bytes": sum(cache["size_in_bytes"] for cache in plan)}))


if __name__ == "__main__":
    main()
