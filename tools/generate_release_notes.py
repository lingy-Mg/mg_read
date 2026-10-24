#!/usr/bin/env python3
"""Generate user-facing release notes from Git commit subjects.

The GitHub release job passes the previous version tag and target commit. This
tool reads local Git history and writes UTF-8 plain text for both the Release
description and Android update manifest. It performs no network access and
omits merge, test, CI, documentation, and build-only commits.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from collections import OrderedDict
from pathlib import Path


CONVENTIONAL = re.compile(
    r"^(?P<kind>[a-z]+)(?:\((?P<scope>[^)]*)\))?!?:\s*(?P<subject>.+)$",
    re.IGNORECASE,
)
IGNORED_KINDS = {"build", "chore", "ci", "docs", "style", "test"}
IGNORED_SCOPES = {"build", "ci", "test", "workflow"}


def classify(subject: str) -> tuple[str | None, str]:
    if re.search(r"\bndk\b|断言|回归测试|只更新.*工作流", subject, re.IGNORECASE):
        return None, ""
    match = CONVENTIONAL.match(subject)
    if match:
        kind = match.group("kind").lower()
        scope = (match.group("scope") or "").lower()
        if kind in IGNORED_KINDS or scope in IGNORED_SCOPES:
            return None, ""
        category = {
            "feat": "新增功能",
            "fix": "问题修复",
            "perf": "性能与体验优化",
            "refactor": "改进",
        }.get(kind, "其他更新")
        return category, match.group("subject").strip()

    if re.match(r"^(?:修复|解决)", subject):
        return "问题修复", subject
    if re.match(r"^(?:新增|增加|添加|支持)", subject):
        return "新增功能", subject
    if re.match(r"^(?:优化|改进|提升|降低)", subject):
        return "性能与体验优化", subject
    if "测试" in subject or "编译产物" in subject or "构建" in subject:
        return None, ""
    return "其他更新", subject


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-tag", default="", help="previous stable version tag")
    parser.add_argument("--to-ref", required=True, help="commit to describe")
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--repository", required=True, help="owner/repository")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    revision_range = f"{args.from_tag}..{args.to_ref}" if args.from_tag else args.to_ref
    result = subprocess.run(
        ["git", "log", "--no-merges", "--format=%s", revision_range],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    entries: OrderedDict[str, list[str]] = OrderedDict(
        (category, []) for category in ("新增功能", "问题修复", "性能与体验优化", "改进", "其他更新")
    )
    for subject in result.stdout.splitlines():
        category, description = classify(subject.strip())
        if category and description and description not in entries[category]:
            entries[category].append(description)

    lines = [f"MgRead {args.release_tag} 更新内容"]
    has_entries = False
    for category, descriptions in entries.items():
        if not descriptions:
            continue
        has_entries = True
        lines.extend(("", category))
        lines.extend(f"- {description}" for description in descriptions)
    if not has_entries:
        lines.extend(("", "本次版本包含维护和稳定性改进。"))

    if args.from_tag:
        compare = f"https://github.com/{args.repository}/compare/{args.from_tag}...{args.release_tag}"
        lines.extend(("", f"完整提交范围：{compare}"))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
