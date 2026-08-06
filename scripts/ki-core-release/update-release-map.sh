#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != 3 ]]; then
    echo "Usage: $0 <ki-core-version> <aioncore-tag> <aioncore-commit>" >&2
    exit 1
fi

ki_core_version="$1"
upstream_tag="$2"
upstream_commit="$3"
repo_root="$(git rev-parse --show-toplevel)"
versions_file="$repo_root/ki-core-versions.json"
version_file="$repo_root/ki-core-version.txt"

if [[ ! "$ki_core_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Ki-Core version must use stable X.Y.Z SemVer" >&2
    exit 1
fi
if [[ ! "$upstream_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "AionCore tag must use vX.Y.Z" >&2
    exit 1
fi
if [[ ! "$upstream_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "AionCore commit must be a full lowercase commit SHA" >&2
    exit 1
fi
if [[ "$(tr -d '[:space:]' < "$version_file")" != "$ki_core_version" ]]; then
    echo "Requested Ki-Core version does not match ki-core-version.txt" >&2
    exit 1
fi

resolved_upstream=""
if git cat-file -e "$upstream_tag^{commit}" 2>/dev/null; then
    resolved_upstream="$(git rev-parse "$upstream_tag^{commit}")"
elif [[ "${KI_CORE_VERIFY_REMOTE_TAG:-0}" == "1" ]]; then
    resolved_upstream="$(git ls-remote --tags https://github.com/iOfficeAI/AionCore.git \
        "refs/tags/$upstream_tag" "refs/tags/$upstream_tag^{}" | awk -v tag="$upstream_tag" '
        $2 == "refs/tags/" tag "^{}" { peeled = $1 }
        $2 == "refs/tags/" tag { direct = $1 }
        END { print (peeled != "" ? peeled : direct) }
    ')"
else
    echo "Mapped AionCore tag is not available locally: $upstream_tag" >&2
    exit 1
fi
if [[ "$resolved_upstream" != "$upstream_commit" ]]; then
    echo "AionCore tag $upstream_tag does not match $upstream_commit" >&2
    exit 1
fi

product_tag="ki-core-v${ki_core_version}"
allow_replace=1
if git cat-file -e "$product_tag^{commit}" 2>/dev/null; then
    allow_replace=0
elif [[ "${KI_CORE_VERIFY_REMOTE_TAG:-0}" == "1" ]]; then
    remote_product_tag="$(git ls-remote --tags origin \
        "refs/tags/$product_tag" "refs/tags/$product_tag^{}" | awk -v tag="$product_tag" '
        $2 == "refs/tags/" tag "^{}" { peeled = $1 }
        $2 == "refs/tags/" tag { direct = $1 }
        END { print (peeled != "" ? peeled : direct) }
    ')"
    if [[ -n "$remote_product_tag" ]]; then
        allow_replace=0
    fi
fi

tmp_file="$(mktemp "${versions_file}.tmp.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

python3 - "$versions_file" "$tmp_file" "$ki_core_version" "$upstream_tag" "$upstream_commit" "$allow_replace" <<'PY'
import json
import pathlib
import re
import sys

source_path = pathlib.Path(sys.argv[1])
target_path = pathlib.Path(sys.argv[2])
version = sys.argv[3]
upstream_tag = sys.argv[4]
upstream_commit = sys.argv[5]
allow_replace = sys.argv[6] == "1"
semver_pattern = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def semver(value: str) -> tuple[int, int, int]:
    match = semver_pattern.fullmatch(value)
    if match is None:
        raise SystemExit(f"Invalid Ki-Core version in mapping: {value}")
    return tuple(int(part) for part in match.groups())


data = json.loads(source_path.read_text())
if data.get("schemaVersion") != 1 or not isinstance(data.get("versions"), list):
    raise SystemExit("ki-core-versions.json must use schemaVersion 1 with a versions array")

entry = {
    "version": version,
    "tag": f"ki-core-v{version}",
    "aionCore": {"tag": upstream_tag, "peeledCommit": upstream_commit},
}
existing_index = next(
    (index for index, item in enumerate(data["versions"]) if item.get("version") == version),
    None,
)
if existing_index is None:
    if data["versions"] and semver(version) <= semver(data["versions"][-1]["version"]):
        raise SystemExit("New Ki-Core mappings must use strictly increasing SemVer order")
    data["versions"].append(entry)
    result = f"Added Ki-Core {version} mapping to {upstream_tag}"
elif data["versions"][existing_index] == entry:
    result = f"Ki-Core {version} already matches the requested mapping"
else:
    if not allow_replace:
        raise SystemExit(f"Ki-Core {version} is already released; its mapping cannot change")
    data["versions"][existing_index] = entry
    result = f"Updated unreleased Ki-Core {version} mapping to {upstream_tag}"

target_path.write_text(json.dumps(data, indent=2) + "\n")
print(result)
PY

mv "$tmp_file" "$versions_file"
trap - EXIT
