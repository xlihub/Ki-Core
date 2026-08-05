#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

version_file="$repo_root/ki-core-version.txt"
upstream_file="$repo_root/ki-core-upstream.json"
versions_file="$repo_root/ki-core-versions.json"

for required_file in "$version_file" "$upstream_file" "$versions_file"; do
    if [[ ! -f "$required_file" ]]; then
        echo "Missing Ki-Core release metadata file: ${required_file#$repo_root/}" >&2
        exit 1
    fi
done

upstream_values="$({
    python3 - "$upstream_file" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Invalid ki-core-upstream.json: {error}")

if data.get("schemaVersion") != 1:
    raise SystemExit("ki-core-upstream.json schemaVersion must be 1")

repository = data.get("repository")
tag = data.get("tag")
commit = data.get("peeledCommit")
if repository != "iOfficeAI/AionCore":
    raise SystemExit("ki-core-upstream.json repository must be iOfficeAI/AionCore")
if not isinstance(tag, str) or re.fullmatch(r"v\d+\.\d+\.\d+", tag) is None:
    raise SystemExit("ki-core-upstream.json tag must use vX.Y.Z")
if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    raise SystemExit("ki-core-upstream.json peeledCommit must be a full lowercase commit SHA")

print(f"{repository}\t{tag}\t{commit}")
PY
} 2>&1)" || {
    echo "$upstream_values" >&2
    exit 1
}

IFS=$'\t' read -r upstream_repository upstream_tag upstream_commit <<< "$upstream_values"

if [[ "${KI_CORE_VERIFY_REMOTE_TAG:-0}" == "1" ]]; then
    if ! remote_refs="$(git ls-remote --tags "https://github.com/${upstream_repository}.git" \
        "refs/tags/$upstream_tag" "refs/tags/$upstream_tag^{}")"; then
        echo "Failed to query remote AionCore tag: $upstream_tag" >&2
        exit 1
    fi
    remote_commit="$(awk -v tag="$upstream_tag" '
        $2 == "refs/tags/" tag "^{}" { peeled = $1 }
        $2 == "refs/tags/" tag { direct = $1 }
        END { print (peeled != "" ? peeled : direct) }
    ' <<< "$remote_refs")"
    if [[ -z "$remote_commit" || "$remote_commit" != "$upstream_commit" ]]; then
        echo "Remote AionCore tag $upstream_tag does not match peeledCommit $upstream_commit" >&2
        exit 1
    fi
else
    if ! resolved_commit="$(git rev-parse --verify "${upstream_tag}^{commit}" 2>/dev/null)"; then
        echo "Mapped AionCore tag is not available locally: $upstream_tag" >&2
        exit 1
    fi

    if [[ "$resolved_commit" != "$upstream_commit" ]]; then
        echo "AionCore tag $upstream_tag resolves to $resolved_commit and does not match peeledCommit $upstream_commit" >&2
        exit 1
    fi
fi

if ! git cat-file -e "${upstream_commit}^{commit}" 2>/dev/null; then
    echo "Mapped AionCore peeled commit is not available in the checkout: $upstream_commit" >&2
    exit 1
fi

history_ref="${KI_CORE_RELEASE_HISTORY_REF:-}"
if [[ -z "$history_ref" ]]; then
    if git rev-parse --verify --quiet origin/product/main >/dev/null; then
        history_ref="origin/product/main"
    elif git rev-parse --verify --quiet product/main >/dev/null; then
        history_ref="product/main"
    fi
fi

history_file=""
if [[ -n "$history_ref" ]] && git cat-file -e "$history_ref:ki-core-versions.json" 2>/dev/null; then
    history_file="$(mktemp)"
    trap 'rm -f "$history_file"' EXIT
    git show "$history_ref:ki-core-versions.json" > "$history_file"
fi

python3 - "$version_file" "$upstream_file" "$versions_file" "$history_file" <<'PY'
import datetime
import json
import pathlib
import re
import sys

version_path = pathlib.Path(sys.argv[1])
upstream_path = pathlib.Path(sys.argv[2])
versions_path = pathlib.Path(sys.argv[3])
history_path = pathlib.Path(sys.argv[4]) if sys.argv[4] else None

semver_pattern = re.compile(r"0|[1-9]\d*")
full_semver_pattern = re.compile(
    rf"({semver_pattern.pattern})\.({semver_pattern.pattern})\.({semver_pattern.pattern})"
)
commit_pattern = re.compile(r"[0-9a-f]{40}")


def load_json(path: pathlib.Path, name: str):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Invalid {name}: {error}") from error


current_version = version_path.read_text().strip()
if full_semver_pattern.fullmatch(current_version) is None:
    raise SystemExit("ki-core-version.txt must contain one stable X.Y.Z version")

upstream = load_json(upstream_path, "ki-core-upstream.json")
mapping = load_json(versions_path, "ki-core-versions.json")
if mapping.get("schemaVersion") != 1:
    raise SystemExit("ki-core-versions.json schemaVersion must be 1")

versions = mapping.get("versions")
status_history = mapping.get("statusHistory")
if not isinstance(versions, list) or not versions:
    raise SystemExit("ki-core-versions.json versions must be a non-empty array")
if not isinstance(status_history, list):
    raise SystemExit("ki-core-versions.json statusHistory must be an array")

if history_path is not None:
    history = load_json(history_path, "historic ki-core-versions.json")
    for field in ("versions", "statusHistory"):
        historic_entries = history.get(field, [])
        current_entries = mapping.get(field, [])
        if current_entries[: len(historic_entries)] != historic_entries:
            raise SystemExit(f"Published mapping history is append-only: {field} was rewritten")

seen_versions = set()
seen_tags = set()
entries_by_version = {}
previous_version = None
for entry in versions:
    if not isinstance(entry, dict):
        raise SystemExit("Each Ki-Core version mapping must be an object")
    version = entry.get("version")
    tag = entry.get("tag")
    provenance = entry.get("aionCore")
    if not isinstance(version, str) or full_semver_pattern.fullmatch(version) is None:
        raise SystemExit("Each Ki-Core mapping version must use X.Y.Z")
    if version in seen_versions:
        raise SystemExit(f"Duplicate Ki-Core version: {version}")
    version_tuple = tuple(int(part) for part in version.split("."))
    if previous_version is not None and version_tuple <= previous_version:
        raise SystemExit("Ki-Core versions must be appended in strictly increasing SemVer order")
    if tag != f"ki-core-v{version}":
        raise SystemExit(f"Ki-Core {version} must use tag ki-core-v{version}")
    if tag in seen_tags:
        raise SystemExit(f"Duplicate Ki-Core tag: {tag}")
    if not isinstance(provenance, dict):
        raise SystemExit(f"Ki-Core {version} must define aionCore provenance")
    if re.fullmatch(r"v\d+\.\d+\.\d+", str(provenance.get("tag"))) is None:
        raise SystemExit(f"Ki-Core {version} has an invalid AionCore tag")
    if commit_pattern.fullmatch(str(provenance.get("peeledCommit"))) is None:
        raise SystemExit(f"Ki-Core {version} has an invalid AionCore peeled commit")
    seen_versions.add(version)
    seen_tags.add(tag)
    entries_by_version[version] = entry
    previous_version = version_tuple

seen_statuses = set()
last_status_rank = {}
status_rank = {"prepared": 0, "published": 1, "deprecated": 2}
for event in status_history:
    if not isinstance(event, dict):
        raise SystemExit("Each Ki-Core status record must be an object")
    version = event.get("version")
    status = event.get("status")
    recorded_at = event.get("recordedAt")
    if version not in entries_by_version:
        raise SystemExit(f"Status record references unknown Ki-Core version: {version}")
    if status not in status_rank:
        raise SystemExit(f"Invalid Ki-Core status for {version}: {status}")
    try:
        datetime.date.fromisoformat(recorded_at)
    except (TypeError, ValueError) as error:
        raise SystemExit(f"Invalid recordedAt date for Ki-Core {version}") from error
    status_key = (version, status)
    if status_key in seen_statuses:
        raise SystemExit(f"Duplicate Ki-Core status record: {version} {status}")
    if status_rank[status] < last_status_rank.get(version, -1):
        raise SystemExit(f"Ki-Core status history is out of order for {version}")
    seen_statuses.add(status_key)
    last_status_rank[version] = status_rank[status]

current_entry = entries_by_version.get(current_version)
if current_entry is None:
    raise SystemExit(f"Current Ki-Core version {current_version} is missing from ki-core-versions.json")
expected_provenance = {
    "tag": upstream.get("tag"),
    "peeledCommit": upstream.get("peeledCommit"),
}
if current_entry.get("aionCore") != expected_provenance:
    raise SystemExit("Current Ki-Core mapping does not match ki-core-upstream.json")
if (current_version, "prepared") not in seen_statuses:
    raise SystemExit(f"Current Ki-Core version {current_version} has no prepared status record")
PY

changed_files="$({
    git diff --name-only --diff-filter=ACDMRTUXB "$upstream_commit" --
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
    echo "Disallowed product overlay paths relative to AionCore $upstream_tag:" >&2
    echo "$disallowed_files" >&2
    exit 1
fi

echo "Ki-Core release metadata validation passed"
