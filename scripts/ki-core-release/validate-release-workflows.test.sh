#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 - \
    .github/workflows/build-manual.yml \
    .github/workflows/release.yml \
    .github/workflows/ci.yml \
    .github/workflows/release-please.yml <<'PY'
import pathlib
import re
import sys

candidate = pathlib.Path(sys.argv[1]).read_text()
stable = pathlib.Path(sys.argv[2]).read_text()
ci = pathlib.Path(sys.argv[3]).read_text()
release_please = pathlib.Path(sys.argv[4]).read_text()


def require(text: str, pattern: str, description: str) -> None:
    if pattern not in text:
        raise SystemExit(f"Missing workflow contract: {description}")


def forbid(text: str, pattern: str, description: str) -> None:
    if pattern in text:
        raise SystemExit(f"Retired workflow behavior remains: {description}")


for pattern, description in (
    ("expected_sha:", "candidate commit input"),
    ("github.ref == 'refs/heads/product/main'", "candidate product/main gate"),
    ("ki-core-candidate-${{ matrix.platform }}", "candidate artifact names"),
    ("retention-days: 7", "candidate retention"),
):
    require(candidate, pattern, description)

for target in (
    "x86_64-unknown-linux-gnu",
    "aarch64-unknown-linux-gnu",
    "x86_64-apple-darwin",
    "aarch64-apple-darwin",
    "x86_64-pc-windows-msvc",
    "aarch64-pc-windows-msvc",
):
    require(candidate, target, f"candidate target {target}")
    require(stable, target, f"stable target {target}")

for pattern, description in (
    ('tags:\n      - "ki-core-v*"', "stable tag trigger"),
    ("workflow_call:", "reusable stable trigger"),
    ("workflow_dispatch:", "manual stable rerun"),
    ("ref: refs/tags/${{ env.RELEASE_TAG }}", "tag checkout"),
    ("ki-core-v${VERSION}-${{ matrix.target }}", "Ki-Core archive names"),
    ("sha256sum ki-core-* > ki-core-checksums.txt", "release checksums"),
    ("gh release upload", "release asset upload"),
    ("--clobber", "idempotent asset rerun"),
):
    require(stable, pattern, description)

for text, pattern, description in (
    (candidate, "build-release-manifest.sh", "candidate provenance manifest"),
    (candidate, "verify-release-assets.sh", "candidate asset verifier"),
    (stable, "candidate_run_id", "candidate precondition for stable release"),
    (stable, "release_commit:", "manual release commit input"),
    (stable, "draft=false", "manual draft promotion"),
    (stable, "repos/${GITHUB_REPOSITORY}/git/refs", "hand-built tag creation"),
):
    forbid(text, pattern, description)

require(release_please, "environment: ki-core-stable", "owner approval before release creation")
require(release_please, "gh workflow run release.yml", "stable build dispatch")

test_job = re.search(r"^  test:\n(?P<body>.*?)(?=^  [a-z][a-z0-9_-]+:\n)", ci, re.DOTALL | re.MULTILINE)
if test_job is None:
    raise SystemExit("CI workflow must define a Test job")
require(ci, "dorny/paths-filter@v4", "workspace path filter")
require(ci, "force_workspace_test:", "manual full-test override")
require(
    test_job.group("body"),
    "needs.changes.outputs.workspace == 'true' || (github.event_name == 'workflow_dispatch' && inputs.force_workspace_test)",
    "runtime-change test gate",
)
require(test_job.group("body"), "cargo nextest run --workspace", "full workspace test command")
require(release_please, "--field force_workspace_test=false", "metadata-only Release Please CI")

print("Ki-Core release workflow contract tests passed")
PY
