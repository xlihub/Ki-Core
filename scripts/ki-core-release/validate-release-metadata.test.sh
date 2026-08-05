#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="$script_dir/validate-release-metadata.sh"
updater="$script_dir/update-release-map.sh"
real_git="$(command -v git)"

if [[ ! -x "$validator" || ! -x "$updater" ]]; then
    echo "Ki-Core release metadata scripts must exist and be executable" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_expect() {
    local cwd="$1"
    local expected_status="$2"
    local expected_text="$3"
    shift 3

    local output
    local status
    set +e
    output="$(cd "$cwd" && "$@" 2>&1)"
    status=$?
    set -e

    if [[ "$status" != "$expected_status" ]]; then
        echo "expected status $expected_status, got $status" >&2
        echo "$output" >&2
        exit 1
    fi

    if [[ "$output" != *"$expected_text"* ]]; then
        echo "expected output to contain: $expected_text" >&2
        echo "$output" >&2
        exit 1
    fi
}

write_metadata() {
    local dir="$1"
    local upstream_commit="$2"

    cat > "$dir/ki-core-version.txt" <<'EOF'
0.1.0
EOF

    cat > "$dir/ki-core-upstream.json" <<EOF
{
  "schemaVersion": 1,
  "repository": "iOfficeAI/AionCore",
  "tag": "v0.1.58",
  "peeledCommit": "$upstream_commit"
}
EOF

    cat > "$dir/ki-core-versions.json" <<EOF
{
  "schemaVersion": 1,
  "versions": [
    {
      "version": "0.1.0",
      "tag": "ki-core-v0.1.0",
      "aionCore": {
        "tag": "v0.1.58",
        "peeledCommit": "$upstream_commit"
      }
    }
  ],
  "statusHistory": [
    {
      "version": "0.1.0",
      "status": "prepared",
      "recordedAt": "2026-08-05"
    }
  ]
}
EOF
}

init_case_repo() {
    local name="$1"
    local dir="$tmpdir/$name"

    mkdir -p "$dir/.github/workflows" "$dir/crates/demo/src" "$dir/scripts/ki-core-release"
    (
        cd "$dir"
        git init -q -b main
        git config user.email test@example.com
        git config user.name "Ki-Core Release Test"
        printf '%s\n' '[workspace]' > Cargo.toml
        printf '%s\n' 'pub fn baseline() {}' > crates/demo/src/lib.rs
        printf '%s\n' 'name: CI' > .github/workflows/ci.yml
        git add .
        git commit -q -m "seed upstream"
        git tag v0.1.58
        git tag v0.1.57
    )

    local upstream_commit
    upstream_commit="$(git -C "$dir" rev-parse HEAD)"
    write_metadata "$dir" "$upstream_commit"
    cp "$validator" "$updater" "$dir/scripts/ki-core-release/"
    chmod +x "$dir/scripts/ki-core-release/"*.sh
    printf '%s\n' 'name: Product CI' > "$dir/.github/workflows/ci.yml"
    (
        cd "$dir"
        git add .
        git commit -q -m "add product release metadata"
        git tag mapping-base
    )

    printf '%s\n' "$dir"
}

valid_repo="$(init_case_repo valid)"
run_expect "$valid_repo" 0 "Ki-Core release metadata validation passed" \
    env KI_CORE_RELEASE_HISTORY_REF=mapping-base bash scripts/ki-core-release/validate-release-metadata.sh

local_tag_missing_repo="$(init_case_repo local-tag-missing)"
git -C "$local_tag_missing_repo" tag -d v0.1.58 v0.1.57 >/dev/null
run_expect "$local_tag_missing_repo" 1 "Mapped AionCore tag is not available locally" \
    env KI_CORE_RELEASE_HISTORY_REF=mapping-base bash scripts/ki-core-release/validate-release-metadata.sh

remote_tag_repo="$(init_case_repo remote-tag)"
remote_tag_commit="$(git -C "$remote_tag_repo" rev-parse 'v0.1.58^{commit}')"
git -C "$remote_tag_repo" tag -d v0.1.58 v0.1.57 >/dev/null
fake_git_dir="$tmpdir/fake-git"
mkdir -p "$fake_git_dir"
cat > "$fake_git_dir/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "ls-remote" ]]; then
    printf '%s\trefs/tags/v0.1.58\n' "$KI_CORE_FAKE_REMOTE_COMMIT"
    exit 0
fi

exec "$KI_CORE_REAL_GIT" "$@"
EOF
chmod +x "$fake_git_dir/git"
run_expect "$remote_tag_repo" 0 "Ki-Core release metadata validation passed" \
    env \
    PATH="$fake_git_dir:$PATH" \
    KI_CORE_REAL_GIT="$real_git" \
    KI_CORE_FAKE_REMOTE_COMMIT="$remote_tag_commit" \
    KI_CORE_VERIFY_REMOTE_TAG=1 \
    KI_CORE_RELEASE_HISTORY_REF=mapping-base \
    bash scripts/ki-core-release/validate-release-metadata.sh

tag_mismatch_repo="$(init_case_repo tag-mismatch)"
python3 - "$tag_mismatch_repo/ki-core-upstream.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["peeledCommit"] = "0000000000000000000000000000000000000000"
path.write_text(json.dumps(data, indent=2) + "\n")
PY
run_expect "$tag_mismatch_repo" 1 "does not match peeledCommit" \
    bash scripts/ki-core-release/validate-release-metadata.sh

source_change_repo="$(init_case_repo source-change)"
printf '%s\n' 'pub fn forbidden_product_change() {}' >> "$source_change_repo/crates/demo/src/lib.rs"
run_expect "$source_change_repo" 1 "Disallowed product overlay paths" \
    bash scripts/ki-core-release/validate-release-metadata.sh

untracked_source_repo="$(init_case_repo untracked-source)"
printf '%s\n' 'pub fn untracked_product_change() {}' > "$untracked_source_repo/crates/demo/src/untracked.rs"
run_expect "$untracked_source_repo" 1 "crates/demo/src/untracked.rs" \
    bash scripts/ki-core-release/validate-release-metadata.sh

patch_repo="$(init_case_repo patch-version)"
patch_upstream_commit="$(git -C "$patch_repo" rev-parse 'v0.1.58^{commit}')"
printf '%s\n' '0.1.1' > "$patch_repo/ki-core-version.txt"
run_expect "$patch_repo" 0 "Added Ki-Core 0.1.1 mapping" \
    env KI_CORE_RECORDED_AT=2026-08-06 bash scripts/ki-core-release/update-release-map.sh \
    0.1.1 v0.1.58 "$patch_upstream_commit"
run_expect "$patch_repo" 0 "Ki-Core release metadata validation passed" \
    env KI_CORE_RELEASE_HISTORY_REF=mapping-base bash scripts/ki-core-release/validate-release-metadata.sh

run_expect "$patch_repo" 0 "already matches the requested mapping" \
    env KI_CORE_RECORDED_AT=2026-08-06 bash scripts/ki-core-release/update-release-map.sh \
    0.1.1 v0.1.58 "$patch_upstream_commit"

regression_repo="$(init_case_repo version-regression)"
regression_upstream_commit="$(git -C "$regression_repo" rev-parse 'v0.1.58^{commit}')"
printf '%s\n' '0.0.9' > "$regression_repo/ki-core-version.txt"
run_expect "$regression_repo" 1 "strictly increasing SemVer order" \
    env KI_CORE_RECORDED_AT=2026-08-06 bash scripts/ki-core-release/update-release-map.sh \
    0.0.9 v0.1.58 "$regression_upstream_commit"
run_expect "$regression_repo" 1 "Current Ki-Core version 0.0.9 is missing" \
    bash scripts/ki-core-release/validate-release-metadata.sh

conflict_repo="$(init_case_repo conflicting-version)"
conflict_upstream_commit="$(git -C "$conflict_repo" rev-parse 'v0.1.58^{commit}')"
run_expect "$conflict_repo" 1 "already exists with different provenance" \
    bash scripts/ki-core-release/update-release-map.sh \
    0.1.0 v0.1.57 "$conflict_upstream_commit"

duplicate_repo="$(init_case_repo duplicate-version)"
python3 - "$duplicate_repo/ki-core-versions.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["versions"].append(data["versions"][0])
path.write_text(json.dumps(data, indent=2) + "\n")
PY
run_expect "$duplicate_repo" 1 "Duplicate Ki-Core version: 0.1.0" \
    bash scripts/ki-core-release/validate-release-metadata.sh

rewrite_repo="$(init_case_repo history-rewrite)"
python3 - "$rewrite_repo/ki-core-versions.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["versions"][0]["tag"] = "ki-core-v0.1.0-rewritten"
path.write_text(json.dumps(data, indent=2) + "\n")
PY
run_expect "$rewrite_repo" 1 "Published mapping history is append-only" \
    env KI_CORE_RELEASE_HISTORY_REF=mapping-base bash scripts/ki-core-release/validate-release-metadata.sh

echo "Ki-Core release metadata script tests passed"
