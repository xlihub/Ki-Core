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
stage_script="scripts/ki-core-release/stage-release-metadata.sh"
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
    "$stage_script"
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

[[ -x "$stage_script" ]] || {
    echo "$stage_script must exist and be executable" >&2
    exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

init_fixture() {
    local fixture="$1"
    mkdir -p "$fixture"
    git -C "$fixture" init -q
    git -C "$fixture" config user.name "Ki-Core Test"
    git -C "$fixture" config user.email "ki-core-test@example.invalid"
    printf '{"tag":"v0.1.0"}\n' >"$fixture/ki-core-upstream.json"
    printf '{"0.1.0":"v0.1.0"}\n' >"$fixture/ki-core-versions.json"
}

missing_pending_fixture="$tmp_dir/missing-pending"
init_fixture "$missing_pending_fixture"
git -C "$missing_pending_fixture" add ki-core-upstream.json ki-core-versions.json
git -C "$missing_pending_fixture" commit -qm "initial metadata"
printf '{"0.1.0":"v0.1.0","0.1.1":"v0.1.0"}\n' >"$missing_pending_fixture/ki-core-versions.json"
(
    cd "$missing_pending_fixture"
    "$repo_root/$stage_script"
)
missing_pending_staged="$(git -C "$missing_pending_fixture" diff --cached --name-only)"
if [[ "$missing_pending_staged" != "ki-core-versions.json" ]]; then
    echo "Metadata staging without pending file produced unexpected paths: $missing_pending_staged" >&2
    exit 1
fi

promoted_pending_fixture="$tmp_dir/promoted-pending"
init_fixture "$promoted_pending_fixture"
printf '{"tag":"v0.1.1"}\n' >"$promoted_pending_fixture/ki-core-upstream-pending.json"
git -C "$promoted_pending_fixture" add ki-core-upstream.json ki-core-upstream-pending.json ki-core-versions.json
git -C "$promoted_pending_fixture" commit -qm "metadata with pending baseline"
mv "$promoted_pending_fixture/ki-core-upstream-pending.json" "$promoted_pending_fixture/ki-core-upstream.json"
printf '{"0.1.0":"v0.1.0","0.1.1":"v0.1.1"}\n' >"$promoted_pending_fixture/ki-core-versions.json"
(
    cd "$promoted_pending_fixture"
    "$repo_root/$stage_script"
)
promoted_pending_staged="$(git -C "$promoted_pending_fixture" diff --cached --name-only | sort)"
expected_promoted_staged=$'ki-core-upstream-pending.json\nki-core-upstream.json\nki-core-versions.json'
if [[ "$promoted_pending_staged" != "$expected_promoted_staged" ]]; then
    echo "Metadata staging after pending promotion produced unexpected paths: $promoted_pending_staged" >&2
    exit 1
fi

echo "Ki-Core Release Please contract tests passed"
