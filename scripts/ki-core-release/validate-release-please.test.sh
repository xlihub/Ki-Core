#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 - release-please-config.json .release-please-manifest.json <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
config = json.loads(config_path.read_text())
manifest = json.loads(manifest_path.read_text())

expected_bootstrap_sha = "532d7fffdb99c4370bb4569fe9179e44980fca15"
if config.get("bootstrap-sha") != expected_bootstrap_sha:
    raise SystemExit("Release Please bootstrap-sha must freeze the pre-Ki-Core product baseline")

package = config.get("packages", {}).get(".")
if not isinstance(package, dict):
    raise SystemExit("Release Please must configure the repository root package")

expected = {
    "package-name": "ki-core",
    "release-type": "simple",
    "version-file": "ki-core-version.txt",
    "changelog-path": "CHANGELOG.ki-core.md",
    "include-component-in-tag": True,
    "include-v-in-tag": True,
    "tag-separator": "-",
    "initial-version": "0.1.0",
    "draft": True,
    "force-tag-creation": False,
}
for key, value in expected.items():
    if package.get(key) != value:
        raise SystemExit(f"Release Please package field {key} must be {value!r}")

if "release-as" in package:
    raise SystemExit("Release Please must not persist a release-as override across release cycles")

if package.get("extra-files"):
    raise SystemExit("Release Please must not update Cargo or other AionCore version files")
if manifest != {".": "0.0.0"}:
    raise SystemExit("The bootstrap manifest must start before Ki-Core 0.1.0")
PY

if [[ "$(tr -d '[:space:]' < ki-core-version.txt)" != "0.1.0" ]]; then
    echo "ki-core-version.txt must hold the prepared 0.1.0 product version" >&2
    exit 1
fi

if [[ ! -f CHANGELOG.ki-core.md ]]; then
    echo "CHANGELOG.ki-core.md must exist" >&2
    exit 1
fi

workflow=".github/workflows/release-please.yml"
required_patterns=(
    "workflow_dispatch:"
    "github.ref == 'refs/heads/product/main'"
    "target-branch: product/main"
    "skip-github-release: true"
    "steps.release-please.outputs.prs_created == 'true'"
    "fromJSON(steps.release-please.outputs.pr).headBranchName"
    "scripts/ki-core-release/update-release-map.sh"
    "scripts/ki-core-release/validate-release-metadata.sh"
    "git push origin \"HEAD:\$release_branch\""
)

for pattern in "${required_patterns[@]}"; do
    if ! grep -Fq "$pattern" "$workflow"; then
        echo "Release Please workflow is missing required contract: $pattern" >&2
        exit 1
    fi
done

for forbidden in "cargo update" "Cargo.lock" "release.yml" "release_created" "--clobber"; do
    if grep -Fqi -- "$forbidden" "$workflow"; then
        echo "Release Please workflow contains forbidden publication/Cargo behavior: $forbidden" >&2
        exit 1
    fi
done

echo "Ki-Core Release Please contract tests passed"
