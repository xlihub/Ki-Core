#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 - release-please-config.json .release-please-manifest.json ki-core-version.txt <<'PY'
import json
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
version_path = pathlib.Path(sys.argv[3])
config = json.loads(config_path.read_text())
manifest = json.loads(manifest_path.read_text())
current_version = version_path.read_text().strip()

stable_semver = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


class ContractError(ValueError):
    pass


def parse_stable_semver(value: object, field: str) -> tuple[int, int, int]:
    if not isinstance(value, str):
        raise ContractError(f"{field} must be a stable SemVer string")
    match = stable_semver.fullmatch(value)
    if match is None:
        raise ContractError(f"{field} must be a stable SemVer string")
    return tuple(int(part) for part in match.groups())


def validate_manifest_state(
    candidate_manifest: object,
    candidate_version: object,
    initial_version: str,
) -> None:
    current = parse_stable_semver(candidate_version, "ki-core-version.txt")
    initial = parse_stable_semver(initial_version, "Release Please initial-version")
    if current < initial:
        raise ContractError("ki-core-version.txt must not precede the initial Ki-Core version")

    if not isinstance(candidate_manifest, dict) or set(candidate_manifest) != {"."}:
        raise ContractError("Release Please manifest must contain only the repository root package")

    manifest_version = candidate_manifest["."]
    manifest_semver = parse_stable_semver(
        manifest_version,
        "Release Please manifest root version",
    )
    if manifest_version == "0.0.0":
        if current != initial:
            raise ContractError("The bootstrap manifest is valid only before the initial release")
        return

    if manifest_semver != current:
        raise ContractError("Release Please manifest must match ki-core-version.txt after bootstrap")

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

initial_version = expected["initial-version"]
try:
    validate_manifest_state(manifest, current_version, initial_version)
except ContractError as error:
    raise SystemExit(str(error)) from error

valid_states = (
    ({".": "0.0.0"}, "0.1.0"),
    ({".": "0.1.0"}, "0.1.0"),
    ({".": "1.4.2"}, "1.4.2"),
)
for candidate_manifest, candidate_version in valid_states:
    validate_manifest_state(candidate_manifest, candidate_version, initial_version)

invalid_states = (
    ({".": "0.0.0"}, "0.2.0"),
    ({".": "0.1.0", "other": "0.1.0"}, "0.1.0"),
    ({".": "0.1"}, "0.1.0"),
    ({".": "0.1.0"}, "0.2.0"),
    ({".": "0.1.0"}, "0.1.0-rc.1"),
)
for candidate_manifest, candidate_version in invalid_states:
    try:
        validate_manifest_state(candidate_manifest, candidate_version, initial_version)
    except ContractError:
        continue
    raise SystemExit(
        f"Release Please manifest validator accepted invalid state: "
        f"{candidate_manifest!r}, {candidate_version!r}"
    )
PY

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
    "KI_CORE_VERIFY_REMOTE_TAG=1 scripts/ki-core-release/update-release-map.sh"
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
