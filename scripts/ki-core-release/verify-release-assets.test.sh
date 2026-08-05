#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
builder="$script_dir/build-release-manifest.sh"
verifier="$script_dir/verify-release-assets.sh"

if [[ ! -x "$builder" || ! -x "$verifier" ]]; then
    echo "Ki-Core release asset scripts must exist and be executable" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_expect() {
    local expected_status="$1"
    local expected_text="$2"
    shift 2

    local output
    local status
    set +e
    output="$("$@" 2>&1)"
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

create_archives() {
    local dir="$1"
    shift
    mkdir -p "$dir"
    python3 - "$dir" "$@" <<'PY'
import io
import pathlib
import sys
import tarfile
import zipfile

directory = pathlib.Path(sys.argv[1])
for platform in sys.argv[2:]:
    targets = {
        "macos-x64": ("x86_64-apple-darwin", "aioncore", "tar"),
        "macos-arm64": ("aarch64-apple-darwin", "aioncore", "tar"),
        "linux-x64": ("x86_64-unknown-linux-gnu", "aioncore", "tar"),
        "linux-arm64": ("aarch64-unknown-linux-gnu", "aioncore", "tar"),
        "windows-x64": ("x86_64-pc-windows-msvc", "aioncore.exe", "zip"),
        "windows-arm64": ("aarch64-pc-windows-msvc", "aioncore.exe", "zip"),
    }
    target, executable, kind = targets[platform]
    suffix = ".zip" if kind == "zip" else ".tar.gz"
    path = directory / f"ki-core-v0.1.0-{target}{suffix}"
    payload = f"fixture:{platform}\n".encode()
    if kind == "zip":
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            info = zipfile.ZipInfo(executable)
            info.external_attr = 0o100755 << 16
            archive.writestr(info, payload)
    else:
        with tarfile.open(path, "w:gz") as archive:
            info = tarfile.TarInfo(executable)
            info.mode = 0o755
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
PY
}

all_platforms=(
    macos-x64
    macos-arm64
    linux-x64
    linux-arm64
    windows-x64
    windows-arm64
)
release_commit="134daddccf129d1642e08e709522f835fb734572"

stable_dir="$tmpdir/stable"
create_archives "$stable_dir" "${all_platforms[@]}"
run_expect 0 "Built stable Ki-Core release manifest" \
    env \
    KI_CORE_REPOSITORY=xlihub/Ki-Core \
    KI_CORE_WORKFLOW=release.yml \
    KI_CORE_RUN_ID=1001 \
    KI_CORE_HEAD_SHA="$release_commit" \
    KI_CORE_RELEASE_COMMIT="$release_commit" \
    KI_CORE_TAG=ki-core-v0.1.0 \
    "$builder" stable "$stable_dir"
run_expect 0 "Verified stable Ki-Core release assets" "$verifier" stable "$stable_dir"

python3 - "$stable_dir/ki-core-release.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest["schemaVersion"] == 1
assert manifest["release"]["type"] == "stable"
assert manifest["product"] == {
    "name": "Ki-Core",
    "version": "0.1.0",
    "tag": "ki-core-v0.1.0",
    "releaseCommit": "134daddccf129d1642e08e709522f835fb734572",
}
assert manifest["upstream"]["repository"] == "iOfficeAI/AionCore"
assert manifest["upstream"]["tag"] == "v0.1.58"
assert manifest["upstream"]["peeledCommit"] == "134daddccf129d1642e08e709522f835fb734572"
assert list(manifest["platforms"]) == [
    "macos-x64",
    "macos-arm64",
    "linux-x64",
    "linux-arm64",
    "windows-x64",
    "windows-arm64",
]
assert len({entry["archive"] for entry in manifest["platforms"].values()}) == 6
PY

candidate_dir="$tmpdir/candidate"
create_archives "$candidate_dir" linux-x64
run_expect 0 "Built candidate Ki-Core release manifest" \
    env \
    KI_CORE_REPOSITORY=xlihub/Ki-Core \
    KI_CORE_WORKFLOW=build-manual.yml \
    KI_CORE_RUN_ID=1002 \
    KI_CORE_HEAD_SHA="$release_commit" \
    "$builder" candidate "$candidate_dir"
run_expect 0 "Verified candidate Ki-Core release assets" "$verifier" candidate "$candidate_dir"

python3 - "$candidate_dir/ki-core-candidate.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest["release"] == {
    "type": "candidate",
    "repository": "xlihub/Ki-Core",
    "workflow": "build-manual.yml",
    "runId": "1002",
    "headSha": "134daddccf129d1642e08e709522f835fb734572",
}
assert manifest["product"]["tag"] is None
assert manifest["product"]["releaseCommit"] is None
assert list(manifest["platforms"]) == ["linux-x64"]
PY

missing_dir="$tmpdir/missing"
cp -R "$stable_dir" "$missing_dir"
rm "$missing_dir/ki-core-v0.1.0-aarch64-apple-darwin.tar.gz"
run_expect 1 "Release asset set does not match the manifest" "$verifier" stable "$missing_dir"

tampered_dir="$tmpdir/tampered"
cp -R "$stable_dir" "$tampered_dir"
printf '%s\n' tampered >> "$tampered_dir/ki-core-v0.1.0-x86_64-apple-darwin.tar.gz"
run_expect 1 "Checksum mismatch" "$verifier" stable "$tampered_dir"

duplicate_checksum_dir="$tmpdir/duplicate-checksum"
cp -R "$stable_dir" "$duplicate_checksum_dir"
head -n 1 "$duplicate_checksum_dir/ki-core-checksums.txt" >> "$duplicate_checksum_dir/ki-core-checksums.txt"
run_expect 1 "Duplicate checksum entry" "$verifier" stable "$duplicate_checksum_dir"

unexpected_dir="$tmpdir/unexpected"
cp -R "$stable_dir" "$unexpected_dir"
printf '%s\n' unexpected > "$unexpected_dir/extra.txt"
run_expect 1 "Unexpected release asset" "$verifier" stable "$unexpected_dir"

wrong_executable_dir="$tmpdir/wrong-executable"
cp -R "$candidate_dir" "$wrong_executable_dir"
python3 - "$wrong_executable_dir/ki-core-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" <<'PY'
import io
import pathlib
import sys
import tarfile

path = pathlib.Path(sys.argv[1])
payload = b"wrong\n"
with tarfile.open(path, "w:gz") as archive:
    info = tarfile.TarInfo("wrong-name")
    info.mode = 0o755
    info.size = len(payload)
    archive.addfile(info, io.BytesIO(payload))
PY
run_expect 1 "Checksum mismatch" "$verifier" candidate "$wrong_executable_dir"

link_dir="$tmpdir/link"
create_archives "$link_dir" linux-x64
python3 - "$link_dir/ki-core-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" <<'PY'
import pathlib
import sys
import tarfile

path = pathlib.Path(sys.argv[1])
with tarfile.open(path, "w:gz") as archive:
    info = tarfile.TarInfo("aioncore")
    info.type = tarfile.SYMTYPE
    info.linkname = "outside"
    archive.addfile(info)
PY
run_expect 0 "Built candidate Ki-Core release manifest" \
    env \
    KI_CORE_REPOSITORY=xlihub/Ki-Core \
    KI_CORE_WORKFLOW=build-manual.yml \
    KI_CORE_RUN_ID=1003 \
    KI_CORE_HEAD_SHA="$release_commit" \
    "$builder" candidate "$link_dir"
run_expect 1 "must contain exactly one regular executable" "$verifier" candidate "$link_dir"

invalid_tag_dir="$tmpdir/invalid-tag"
create_archives "$invalid_tag_dir" linux-x64
run_expect 1 "KI_CORE_TAG must use ki-core-vX.Y.Z" \
    env \
    KI_CORE_REPOSITORY=xlihub/Ki-Core \
    KI_CORE_WORKFLOW=release.yml \
    KI_CORE_RUN_ID=1004 \
    KI_CORE_HEAD_SHA="$release_commit" \
    KI_CORE_RELEASE_COMMIT="$release_commit" \
    KI_CORE_TAG=v0.1.0 \
    "$builder" stable "$invalid_tag_dir"

echo "Ki-Core release asset tests passed"
