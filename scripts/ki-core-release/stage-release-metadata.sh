#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

metadata_paths=(
    ki-core-upstream.json
    ki-core-versions.json
)

pending_path="ki-core-upstream-pending.json"
if [[ -e "$pending_path" ]] || git ls-files --error-unmatch -- "$pending_path" >/dev/null 2>&1; then
    metadata_paths+=("$pending_path")
fi

git add -A -- "${metadata_paths[@]}"
