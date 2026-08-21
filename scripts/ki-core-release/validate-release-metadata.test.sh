#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="$script_dir/validate-release-metadata.sh"
updater="$script_dir/update-release-map.sh"

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
        printf '%s\n' 'name: Upstream CI' > .github/workflows/ci.yml
        git add .
        git commit -q -m "seed upstream"
        git tag v0.1.59

        printf '%s\n' 'pub fn next_upstream() {}' > crates/demo/src/lib.rs
        git add crates/demo/src/lib.rs
        git commit -q -m "update upstream"
        git tag v0.1.60

        git checkout -q -b product v0.1.59
    )

    local upstream_commit
    upstream_commit="$(git -C "$dir" rev-parse HEAD)"
    cat > "$dir/ki-core-version.txt" <<'EOF'
0.1.0
EOF
    cat > "$dir/ki-core-upstream.json" <<EOF
{
  "schemaVersion": 1,
  "repository": "iOfficeAI/AionCore",
  "tag": "v0.1.59",
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
        "tag": "v0.1.59",
        "peeledCommit": "$upstream_commit"
      }
    }
  ]
}
EOF
    cp "$validator" "$updater" "$dir/scripts/ki-core-release/"
    chmod +x "$dir/scripts/ki-core-release/"*.sh
    printf '%s\n' 'name: Product CI' > "$dir/.github/workflows/ci.yml"
    (
        cd "$dir"
        git add .
        git commit -q -m "add product release metadata"
    )
    printf '%s\n' "$dir"
}

valid_repo="$(init_case_repo valid)"
run_expect "$valid_repo" 0 "Ki-Core release metadata validation passed" \
    bash scripts/ki-core-release/validate-release-metadata.sh

allowed_overlay_repo="$(init_case_repo allowed-product-overlay)"
mkdir -p \
    "$allowed_overlay_repo/crates/aionui-app/assets/builtin-assistants/rules" \
    "$allowed_overlay_repo/crates/aionui-app/assets/builtin-skills/product-assistant" \
    "$allowed_overlay_repo/crates/aionui-app/tests"
printf '%s\n' '{"version":"1.0.0","assistants":[]}' \
    > "$allowed_overlay_repo/crates/aionui-app/assets/builtin-assistants/assistants.json"
printf '%s\n' '# Product assistant rule' \
    > "$allowed_overlay_repo/crates/aionui-app/assets/builtin-assistants/rules/product-assistant.en-US.md"
printf '%s\n' '# Product assistant skill' \
    > "$allowed_overlay_repo/crates/aionui-app/assets/builtin-skills/product-assistant/SKILL.md"
printf '%s\n' '#[test] fn product_assistant_is_available() {}' \
    > "$allowed_overlay_repo/crates/aionui-app/tests/assistants_e2e.rs"
run_expect "$allowed_overlay_repo" 0 "Ki-Core release metadata validation passed" \
    bash scripts/ki-core-release/validate-release-metadata.sh

update_repo="$(init_case_repo update-current)"
update_commit="$(git -C "$update_repo" rev-parse 'v0.1.60^{commit}')"
git -C "$update_repo" show 'v0.1.60:crates/demo/src/lib.rs' > "$update_repo/crates/demo/src/lib.rs"
python3 - "$update_repo/ki-core-upstream.json" "$update_commit" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["tag"] = "v0.1.60"
data["peeledCommit"] = sys.argv[2]
path.write_text(json.dumps(data, indent=2) + "\n")
PY
run_expect "$update_repo" 0 "Updated unreleased Ki-Core 0.1.0 mapping to v0.1.60" \
    bash scripts/ki-core-release/update-release-map.sh 0.1.0 v0.1.60 "$update_commit"
run_expect "$update_repo" 0 "Ki-Core release metadata validation passed" \
    bash scripts/ki-core-release/validate-release-metadata.sh

pending_repo="$(init_case_repo pending-upstream)"
pending_commit="$(git -C "$pending_repo" rev-parse 'v0.1.60^{commit}')"
git -C "$pending_repo" show 'v0.1.60:crates/demo/src/lib.rs' > "$pending_repo/crates/demo/src/lib.rs"
cat > "$pending_repo/ki-core-upstream-pending.json" <<EOF
{
  "schemaVersion": 1,
  "repository": "iOfficeAI/AionCore",
  "tag": "v0.1.60",
  "peeledCommit": "$pending_commit"
}
EOF
run_expect "$pending_repo" 0 "Ki-Core release metadata validation passed" \
    bash scripts/ki-core-release/validate-release-metadata.sh
printf '%s\n' '0.1.1' > "$pending_repo/ki-core-version.txt"
mv "$pending_repo/ki-core-upstream-pending.json" "$pending_repo/ki-core-upstream.json"
run_expect "$pending_repo" 0 "Added Ki-Core 0.1.1 mapping to v0.1.60" \
    bash scripts/ki-core-release/update-release-map.sh 0.1.1 v0.1.60 "$pending_commit"
run_expect "$pending_repo" 0 "Ki-Core release metadata validation passed" \
    bash scripts/ki-core-release/validate-release-metadata.sh

invalid_pending_repo="$(init_case_repo invalid-pending-upstream)"
cat > "$invalid_pending_repo/ki-core-upstream-pending.json" <<'EOF'
{
  "schemaVersion": 1,
  "repository": "iOfficeAI/AionCore",
  "tag": "v0.1.60",
  "peeledCommit": "0000000000000000000000000000000000000000"
}
EOF
run_expect "$invalid_pending_repo" 1 "does not match peeledCommit" \
    bash scripts/ki-core-release/validate-release-metadata.sh

next_repo="$(init_case_repo next-version)"
next_commit="$(git -C "$next_repo" rev-parse 'v0.1.59^{commit}')"
printf '%s\n' '0.1.1' > "$next_repo/ki-core-version.txt"
run_expect "$next_repo" 0 "Added Ki-Core 0.1.1 mapping to v0.1.59" \
    bash scripts/ki-core-release/update-release-map.sh 0.1.1 v0.1.59 "$next_commit"
run_expect "$next_repo" 0 "Ki-Core release metadata validation passed" \
    bash scripts/ki-core-release/validate-release-metadata.sh

released_repo="$(init_case_repo released-version)"
released_commit="$(git -C "$released_repo" rev-parse 'v0.1.60^{commit}')"
git -C "$released_repo" tag ki-core-v0.1.0
run_expect "$released_repo" 1 "is already released; its mapping cannot change" \
    bash scripts/ki-core-release/update-release-map.sh 0.1.0 v0.1.60 "$released_commit"

source_change_repo="$(init_case_repo source-change)"
printf '%s\n' 'pub fn forbidden_product_change() {}' >> "$source_change_repo/crates/demo/src/lib.rs"
run_expect "$source_change_repo" 1 "Disallowed product overlay paths" \
    bash scripts/ki-core-release/validate-release-metadata.sh

legacy_status_repo="$(init_case_repo legacy-status)"
python3 - "$legacy_status_repo/ki-core-versions.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["statusHistory"] = []
path.write_text(json.dumps(data, indent=2) + "\n")
PY
run_expect "$legacy_status_repo" 1 "must contain only schemaVersion 1 and versions" \
    bash scripts/ki-core-release/validate-release-metadata.sh

echo "Ki-Core release metadata tests passed"
