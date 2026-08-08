#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

version_file="ki-core-version.txt"
upstream_file="ki-core-upstream.json"
pending_upstream_file="ki-core-upstream-pending.json"
versions_file="ki-core-versions.json"

for required_file in "$version_file" "$upstream_file" "$versions_file"; do
    if [[ ! -f "$required_file" ]]; then
        echo "Missing Ki-Core release metadata file: $required_file" >&2
        exit 1
    fi
done

metadata_values="$(python3 - "$version_file" "$upstream_file" "$versions_file" "$pending_upstream_file" <<'PY'
import json
import pathlib
import re
import sys

version_path = pathlib.Path(sys.argv[1])
upstream_path = pathlib.Path(sys.argv[2])
versions_path = pathlib.Path(sys.argv[3])
pending_upstream_path = pathlib.Path(sys.argv[4])
semver_pattern = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
tag_pattern = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
sha_pattern = re.compile(r"^[0-9a-f]{40}$")


def parse_semver(value: object, field: str) -> tuple[int, int, int]:
    if not isinstance(value, str):
        raise SystemExit(f"{field} must be a stable SemVer string")
    match = semver_pattern.fullmatch(value)
    if match is None:
        raise SystemExit(f"{field} must be a stable SemVer string")
    return tuple(int(part) for part in match.groups())


current_version = version_path.read_text().strip()
parse_semver(current_version, "ki-core-version.txt")
mapping = json.loads(versions_path.read_text())

def read_upstream(path: pathlib.Path) -> dict[str, object]:
    upstream = json.loads(path.read_text())
    if upstream.get("schemaVersion") != 1:
        raise SystemExit(f"{path.name} schemaVersion must be 1")
    if upstream.get("repository") != "iOfficeAI/AionCore":
        raise SystemExit(f"{path.name} repository must be iOfficeAI/AionCore")
    if tag_pattern.fullmatch(upstream.get("tag", "")) is None:
        raise SystemExit(f"{path.name} tag must use vX.Y.Z")
    if sha_pattern.fullmatch(upstream.get("peeledCommit", "")) is None:
        raise SystemExit(f"{path.name} peeledCommit must be a full lowercase commit SHA")
    return upstream


upstream = read_upstream(upstream_path)
comparison_upstream = upstream
if pending_upstream_path.exists():
    pending_upstream = read_upstream(pending_upstream_path)
    if pending_upstream == upstream:
        raise SystemExit("Pending AionCore upstream must differ from the published upstream")
    comparison_upstream = pending_upstream

if set(mapping) != {"schemaVersion", "versions"} or mapping.get("schemaVersion") != 1:
    raise SystemExit("ki-core-versions.json must contain only schemaVersion 1 and versions")
entries = mapping.get("versions")
if not isinstance(entries, list) or not entries:
    raise SystemExit("ki-core-versions.json versions must be a non-empty array")

seen_versions: set[str] = set()
previous_semver: tuple[int, int, int] | None = None
for entry in entries:
    if not isinstance(entry, dict) or set(entry) != {"version", "tag", "aionCore"}:
        raise SystemExit("Each Ki-Core mapping must contain version, tag, and aionCore")
    version = entry.get("version")
    parsed = parse_semver(version, "Ki-Core mapping version")
    if previous_semver is not None and parsed <= previous_semver:
        raise SystemExit("Ki-Core mappings must use strictly increasing SemVer order")
    if version in seen_versions:
        raise SystemExit(f"Duplicate Ki-Core mapping version: {version}")
    if entry.get("tag") != f"ki-core-v{version}":
        raise SystemExit(f"Ki-Core mapping tag does not match version {version}")
    provenance = entry.get("aionCore")
    if not isinstance(provenance, dict) or set(provenance) != {"tag", "peeledCommit"}:
        raise SystemExit(f"Ki-Core mapping {version} has invalid AionCore provenance")
    if tag_pattern.fullmatch(provenance.get("tag", "")) is None:
        raise SystemExit(f"Ki-Core mapping {version} has an invalid AionCore tag")
    if sha_pattern.fullmatch(provenance.get("peeledCommit", "")) is None:
        raise SystemExit(f"Ki-Core mapping {version} has an invalid AionCore commit")
    seen_versions.add(version)
    previous_semver = parsed

current_entry = entries[-1]
if current_entry.get("version") != current_version:
    raise SystemExit("ki-core-version.txt must match the latest Ki-Core mapping")
expected_provenance = {
    "tag": upstream.get("tag"),
    "peeledCommit": upstream.get("peeledCommit"),
}
if current_entry.get("aionCore") != expected_provenance:
    raise SystemExit("Current Ki-Core mapping does not match ki-core-upstream.json")

print(
    upstream["tag"],
    upstream["peeledCommit"],
    comparison_upstream["tag"],
    comparison_upstream["peeledCommit"],
)
PY
)"

read -r upstream_tag upstream_commit comparison_tag comparison_commit <<< "$metadata_values"

verify_upstream_commit() {
    local tag="$1"
    local commit="$2"
    local metadata_file="$3"
    local resolved_commit=""

    if git cat-file -e "$tag^{commit}" 2>/dev/null; then
        resolved_commit="$(git rev-parse "$tag^{commit}")"
    elif [[ "${KI_CORE_VERIFY_REMOTE_TAG:-0}" == "1" ]]; then
        resolved_commit="$(git ls-remote --tags https://github.com/iOfficeAI/AionCore.git \
            "refs/tags/$tag" "refs/tags/$tag^{}" | awk -v tag="$tag" '
            $2 == "refs/tags/" tag "^{}" { peeled = $1 }
            $2 == "refs/tags/" tag { direct = $1 }
            END { print (peeled != "" ? peeled : direct) }
        ')"
    else
        echo "Mapped AionCore tag is not available locally: $tag" >&2
        exit 1
    fi
    if [[ "$resolved_commit" != "$commit" ]]; then
        echo "Mapped AionCore tag $tag does not match peeledCommit in $metadata_file" >&2
        exit 1
    fi
}

verify_upstream_commit "$upstream_tag" "$upstream_commit" "$upstream_file"
if [[ -f "$pending_upstream_file" ]]; then
    verify_upstream_commit "$comparison_tag" "$comparison_commit" "$pending_upstream_file"
fi

changed_files="$({
    git diff --name-only --diff-filter=ACDMRTUXB "$comparison_commit" --
    git ls-files --others --exclude-standard
} | sort -u)"

disallowed_files=""
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
        .github/workflows/* | \
            .release-please-manifest.json | \
            release-please-config.json | \
            CHANGELOG.ki-core.md | \
            ki-core-version.txt | \
            ki-core-upstream.json | \
            ki-core-upstream-pending.json | \
            ki-core-versions.json | \
            scripts/ki-core-release/* | \
            docs/* | \
            README.md | README.*.md | \
            CONTRIBUTING.md | CONTRIBUTING.*.md | \
            AGENTS.md | ARCHITECTURE.md | SECURITY.md | \
            Justfile | justfile)
            ;;
        *)
            disallowed_files+="${disallowed_files:+$'\n'}$path"
            ;;
    esac
done <<< "$changed_files"

if [[ -n "$disallowed_files" ]]; then
    echo "Disallowed product overlay paths relative to AionCore $comparison_tag:" >&2
    echo "$disallowed_files" >&2
    exit 1
fi

echo "Ki-Core release metadata validation passed"
