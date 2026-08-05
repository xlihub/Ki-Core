#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 - .github/workflows/build-manual.yml .github/workflows/release.yml <<'PY'
import pathlib
import re
import sys

candidate = pathlib.Path(sys.argv[1]).read_text()
stable = pathlib.Path(sys.argv[2]).read_text()


def require(text: str, pattern: str, description: str) -> None:
    if pattern not in text:
        raise SystemExit(f"Missing workflow contract: {description}")


def forbid(text: str, pattern: str, description: str) -> None:
    if pattern in text:
        raise SystemExit(f"Forbidden workflow behavior: {description}")


for pattern, description in [
    ("expected_sha:", "candidate expected SHA input"),
    ('github.ref == \'refs/heads/product/main\'', "candidate product/main ref gate"),
    ('github.sha', "candidate workflow head SHA"),
    ('ki-core-candidate-${{ matrix.platform }}', "canonical candidate artifact name"),
    ('build-release-manifest.sh candidate', "candidate manifest generation"),
    ('verify-release-assets.sh candidate', "candidate asset verification"),
    ('KI_CORE_WORKFLOW: build-manual.yml', "candidate workflow provenance"),
]:
    require(candidate, pattern, description)

for platform in (
    "macos-x64",
    "macos-arm64",
    "linux-x64",
    "linux-arm64",
    "windows-x64",
    "windows-arm64",
):
    require(candidate, f'"platform":"{platform}"', f"candidate platform {platform}")

for pattern, description in [
    ("tag_name:", "stable tag input"),
    ("release_commit:", "stable commit input"),
    ("candidate_run_id:", "candidate run input"),
    ("permissions: read-all", "read-only workflow default"),
    ("environment: ki-core-stable", "protected publication environment"),
    ("contents: write", "publication write permission"),
    ('build-release-manifest.sh stable', "stable manifest generation"),
    ('verify-release-assets.sh stable', "stable asset verification"),
    ('KI_CORE_WORKFLOW: release.yml', "stable workflow provenance"),
    ("Create draft with Release Please", "protected draft creation"),
    ("skip-github-pull-request: true", "Release Please release-only mode"),
    ('gh release edit "$RELEASE_TAG" --draft=false', "draft promotion"),
    ('actions/workflows/build-manual.yml', "candidate workflow identity check"),
    ('.conclusion == "success"', "candidate conclusion check"),
    ('.head_sha == $release_commit', "candidate head SHA check"),
]:
    require(stable, pattern, description)

if stable.count("contents: write") != 1:
    raise SystemExit("Only the publication job may request contents: write")

for pattern, description in [
    ("--clobber", "release asset overwrite"),
    ('tags:\n', "tag push trigger"),
    ("workflow_call:", "reusable publication trigger"),
    ('ref: refs/tags/', "pre-existing tag checkout"),
]:
    forbid(stable, pattern, description)

if not re.search(r"on:\n  workflow_dispatch:\n", stable):
    raise SystemExit("Stable release workflow must be dispatch-only")

print("Ki-Core release workflow contract tests passed")
PY
