#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != 3 ]]; then
    echo "Usage: $0 <ki-core-version> <aioncore-tag> <aioncore-peeled-commit>" >&2
    exit 2
fi

ki_core_version="$1"
aioncore_tag="$2"
aioncore_commit="$3"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
version_file="$repo_root/ki-core-version.txt"
upstream_file="$repo_root/ki-core-upstream.json"
versions_file="$repo_root/ki-core-versions.json"
validator="$script_dir/validate-release-metadata.sh"
recorded_at="${KI_CORE_RECORDED_AT:-$(date -u +%F)}"

if [[ "$(tr -d '[:space:]' < "$version_file")" != "$ki_core_version" ]]; then
    echo "ki-core-version.txt does not match requested version $ki_core_version" >&2
    exit 1
fi

existing_state="$({
    python3 - "$versions_file" "$ki_core_version" "$aioncore_tag" "$aioncore_commit" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
tag = sys.argv[3]
commit = sys.argv[4]
data = json.loads(path.read_text())
expected = {
    "version": version,
    "tag": f"ki-core-v{version}",
    "aionCore": {"tag": tag, "peeledCommit": commit},
}
matches = [entry for entry in data.get("versions", []) if entry.get("version") == version]
if not matches:
    print("absent")
elif len(matches) == 1 and matches[0] == expected:
    print("exact")
else:
    raise SystemExit(f"Ki-Core version {version} already exists with different provenance")
PY
} 2>&1)" || {
    echo "$existing_state" >&2
    exit 1
}

if [[ "$existing_state" == "exact" ]]; then
    bash "$validator"
    echo "Ki-Core $ki_core_version already matches the requested mapping"
    exit 0
fi

upstream_values="$(python3 - "$upstream_file" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(f"{data.get('tag', '')}\t{data.get('peeledCommit', '')}")
PY
)"
IFS=$'\t' read -r mapped_tag mapped_commit <<< "$upstream_values"
if [[ "$mapped_tag" != "$aioncore_tag" || "$mapped_commit" != "$aioncore_commit" ]]; then
    echo "Requested AionCore provenance does not match ki-core-upstream.json" >&2
    exit 1
fi

if ! resolved_commit="$(git -C "$repo_root" rev-parse --verify "${aioncore_tag}^{commit}" 2>/dev/null)"; then
    echo "Mapped AionCore tag is not available locally: $aioncore_tag" >&2
    exit 1
fi
if [[ "$resolved_commit" != "$aioncore_commit" ]]; then
    echo "AionCore tag $aioncore_tag does not match requested commit $aioncore_commit" >&2
    exit 1
fi

backup_file="$(mktemp)"
cp "$versions_file" "$backup_file"
cleanup() {
    rm -f "$backup_file"
}
trap cleanup EXIT

python3 - "$versions_file" "$ki_core_version" "$aioncore_tag" "$aioncore_commit" "$recorded_at" <<'PY'
import datetime
import json
import os
import pathlib
import re
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
tag = sys.argv[3]
commit = sys.argv[4]
recorded_at = sys.argv[5]

if re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version) is None:
    raise SystemExit("Ki-Core version must use stable X.Y.Z SemVer")
if re.fullmatch(r"v\d+\.\d+\.\d+", tag) is None:
    raise SystemExit("AionCore tag must use vX.Y.Z")
if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    raise SystemExit("AionCore peeled commit must be a full lowercase SHA")
try:
    datetime.date.fromisoformat(recorded_at)
except ValueError as error:
    raise SystemExit("KI_CORE_RECORDED_AT must use YYYY-MM-DD") from error

data = json.loads(path.read_text())
data.setdefault("versions", []).append(
    {
        "version": version,
        "tag": f"ki-core-v{version}",
        "aionCore": {"tag": tag, "peeledCommit": commit},
    }
)
data.setdefault("statusHistory", []).append(
    {"version": version, "status": "prepared", "recordedAt": recorded_at}
)

with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
    temporary_path = handle.name
os.replace(temporary_path, path)
PY

if ! bash "$validator"; then
    cp "$backup_file" "$versions_file"
    echo "Restored ki-core-versions.json after validation failure" >&2
    exit 1
fi

echo "Added Ki-Core $ki_core_version mapping to AionCore $aioncore_tag ($aioncore_commit)"
