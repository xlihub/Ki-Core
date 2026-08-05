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

stable_platforms = (
    "macos-x64",
    "macos-arm64",
    "linux-x64",
    "linux-arm64",
    "windows-x64",
    "windows-arm64",
)
stable_matrix = re.search(r"matrix:\n\s+include:\n(?P<body>.*?)(?=\n\s+steps:)", stable, re.DOTALL)
if stable_matrix is None:
    raise SystemExit("Stable release workflow must define an explicit platform matrix")
actual_stable_platforms = re.findall(r"^\s+- platform: ([a-z0-9-]+)$", stable_matrix.group("body"), re.MULTILINE)
if tuple(actual_stable_platforms) != stable_platforms:
    raise SystemExit("Stable release workflow must build the exact six canonical platforms in order")

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
    ('releases?per_page=100', "paginated draft lookup"),
    ('releases/${RELEASE_ID}', "release ID draft promotion"),
    ('-F draft=false', "draft promotion"),
    ('releases/assets/${asset_id}', "release asset ID download"),
    ('published_tag', "published tag target verification"),
    ('repos/${GITHUB_REPOSITORY}/git/refs', "atomic verified tag creation"),
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
    ('releases/tags/${RELEASE_TAG}', "published-only tag lookup for a draft"),
    ('gh release upload', "tag-based draft asset upload"),
    ('gh release download', "tag-based draft asset download"),
    ('gh release edit', "tag-based draft publication"),
]:
    forbid(stable, pattern, description)

if not re.search(r"on:\n  workflow_dispatch:\n", stable):
    raise SystemExit("Stable release workflow must be dispatch-only")

test_job = re.search(r"^  test:\n(?P<body>.*?)(?=^  [a-z][a-z0-9_-]+:\n)", ci, re.DOTALL | re.MULTILINE)
if test_job is None:
    raise SystemExit("CI workflow must define a Test job")

for pattern, description in [
    ("force_workspace_test:", "manual workspace test override input"),
    ("type: boolean", "Boolean manual workspace test override"),
    ("default: true", "full workspace tests by default for manual CI"),
    ("workspace: ${{ steps.filter.outputs.workspace }}", "workspace change output"),
    ("dorny/paths-filter@v4", "Node 24 path filter"),
    ("list-files: shell", "observable workspace path matches"),
    ("'.cargo/**'", "Cargo configuration impact path"),
    ("'.github/workflows/ci.yml'", "CI workflow self-validation path"),
    ("'Cargo.toml'", "workspace manifest impact path"),
    ("'Cargo.lock'", "dependency lock impact path"),
    ("'rust-toolchain.toml'", "Rust toolchain impact path"),
    ("'crates/**'", "workspace source and fixture impact path"),
]:
    require(ci, pattern, description)

for pattern, description in [
    ("needs: changes", "workspace change dependency"),
    (
        "needs.changes.outputs.workspace == 'true' || (github.event_name == 'workflow_dispatch' && inputs.force_workspace_test)",
        "runtime changes or explicit manual override gate",
    ),
    ("cargo nextest run --workspace", "full workspace test command"),
]:
    require(test_job.group("body"), pattern, description)

for pattern in (
    "scripts/ki-core-release/**",
    ".release-please-manifest.json",
    "CHANGELOG.ki-core.md",
):
    forbid(ci, pattern, f"release-only path classified as workspace test input: {pattern}")

require(
    release_please,
    "-f force_workspace_test=false",
    "Release Please metadata-only CI dispatch",
)


def should_run_workspace_test(event: str, workspace_changed: bool, force: bool) -> bool:
    return workspace_changed or (event == "workflow_dispatch" and force)


expected_test_decisions = (
    ("pull_request", True, False, True),
    ("pull_request", False, False, False),
    ("push", True, False, True),
    ("push", False, False, False),
    ("workflow_dispatch", True, False, True),
    ("workflow_dispatch", False, False, False),
    ("workflow_dispatch", False, True, True),
)
for event, workspace_changed, force, expected_decision in expected_test_decisions:
    actual_decision = should_run_workspace_test(event, workspace_changed, force)
    if actual_decision != expected_decision:
        raise SystemExit(
            "Workspace test decision mismatch for "
            f"event={event}, workspace_changed={workspace_changed}, force={force}"
        )

print("Ki-Core release workflow contract tests passed")
PY
