#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 - release-please-config.json .release-please-manifest.json ki-core-version.txt <<'PY'
import json
import pathlib
import re
import sys

config = json.loads(pathlib.Path(sys.argv[1]).read_text())
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
current_version = pathlib.Path(sys.argv[3]).read_text().strip()
semver = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")

if semver.fullmatch(current_version) is None:
    raise SystemExit("ki-core-version.txt must contain stable X.Y.Z SemVer")
if manifest != {".": current_version}:
    raise SystemExit("Release Please manifest must match ki-core-version.txt")
if config.get("bootstrap-sha") != "532d7fffdb99c4370bb4569fe9179e44980fca15":
    raise SystemExit("Release Please bootstrap-sha must preserve the product baseline")

package = config.get("packages", {}).get(".")
expected = {
    "package-name": "ki-core",
    "release-type": "simple",
    "version-file": "ki-core-version.txt",
    "changelog-path": "CHANGELOG.ki-core.md",
    "include-component-in-tag": True,
    "include-v-in-tag": True,
    "tag-separator": "-",
    "initial-version": "0.1.0",
    "draft": False,
    "force-tag-creation": False,
}
if not isinstance(package, dict):
    raise SystemExit("Release Please must configure the repository root package")
for key, value in expected.items():
    if package.get(key) != value:
        raise SystemExit(f"Release Please package field {key} must be {value!r}")
if "release-as" in package:
    raise SystemExit("Release Please must not persist a release-as override")
if package.get("extra-files"):
    raise SystemExit("Release Please must not modify AionCore runtime version files")
PY

[[ -f CHANGELOG.ki-core.md ]] || {
    echo "CHANGELOG.ki-core.md must exist" >&2
    exit 1
}

workflow=".github/workflows/release-please.yml"
required_patterns=(
    "workflow_dispatch:"
    "operation:"
    "release-current"
    "github.ref == 'refs/heads/product/main'"
    "contains(github.event.head_commit.message, 'chore(product/main): release')"
    "environment: ki-core-stable"
    "skip-github-pull-request: true"
    "skip-github-release: true"
    "gh workflow run release.yml"
    "fromJSON(steps.release-please.outputs.pr).headBranchName"
    "scripts/ki-core-release/update-release-map.sh"
    "scripts/ki-core-release/validate-release-metadata.sh"
    "mv ki-core-upstream-pending.json ki-core-upstream.json"
    "git add -A ki-core-upstream.json ki-core-upstream-pending.json ki-core-versions.json"
    "--field force_workspace_test=false"
)
for pattern in "${required_patterns[@]}"; do
    if ! grep -Fq -- "$pattern" "$workflow"; then
        echo "Release Please workflow is missing required contract: $pattern" >&2
        exit 1
    fi
done

for forbidden in "candidate_run_id" "Create draft" "draft=false" "git/refs"; do
    if grep -Fqi -- "$forbidden" "$workflow"; then
        echo "Release Please workflow contains retired release behavior: $forbidden" >&2
        exit 1
    fi
done

echo "Ki-Core Release Please contract tests passed"
