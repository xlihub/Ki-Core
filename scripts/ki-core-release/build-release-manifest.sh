#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != 2 ]]; then
    echo "Usage: $0 <candidate|stable> <assets-directory>" >&2
    exit 2
fi

source_type="$1"
assets_dir="$2"
repo_root="$(git rev-parse --show-toplevel)"

if [[ "$source_type" != "candidate" && "$source_type" != "stable" ]]; then
    echo "Release source type must be candidate or stable" >&2
    exit 2
fi
if [[ ! -d "$assets_dir" ]]; then
    echo "Release assets directory does not exist: $assets_dir" >&2
    exit 1
fi

python3 - \
    "$source_type" \
    "$assets_dir" \
    "$repo_root/ki-core-version.txt" \
    "$repo_root/ki-core-upstream.json" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile

source_type = sys.argv[1]
assets_dir = pathlib.Path(sys.argv[2]).resolve()
version_file = pathlib.Path(sys.argv[3])
upstream_file = pathlib.Path(sys.argv[4])

platform_contract = {
    "macos-x64": ("x86_64-apple-darwin", "aioncore", ".tar.gz"),
    "macos-arm64": ("aarch64-apple-darwin", "aioncore", ".tar.gz"),
    "linux-x64": ("x86_64-unknown-linux-gnu", "aioncore", ".tar.gz"),
    "linux-arm64": ("aarch64-unknown-linux-gnu", "aioncore", ".tar.gz"),
    "windows-x64": ("x86_64-pc-windows-msvc", "aioncore.exe", ".zip"),
    "windows-arm64": ("aarch64-pc-windows-msvc", "aioncore.exe", ".zip"),
}
sha_pattern = re.compile(r"[0-9a-f]{40}")
semver_pattern = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")


def require_env(name: str, pattern: re.Pattern[str] | None = None) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"{name} is required")
    if pattern is not None and pattern.fullmatch(value) is None:
        raise SystemExit(f"{name} has an invalid value")
    return value


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: pathlib.Path, value: object) -> None:
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
        temporary_path = pathlib.Path(handle.name)
    temporary_path.replace(path)


version = version_file.read_text().strip()
if semver_pattern.fullmatch(version) is None:
    raise SystemExit("ki-core-version.txt must contain stable X.Y.Z SemVer")

upstream = json.loads(upstream_file.read_text())
if upstream.get("repository") != "iOfficeAI/AionCore":
    raise SystemExit("ki-core-upstream.json has an unexpected repository")
if re.fullmatch(r"v\d+\.\d+\.\d+", str(upstream.get("tag"))) is None:
    raise SystemExit("ki-core-upstream.json has an invalid tag")
if sha_pattern.fullmatch(str(upstream.get("peeledCommit"))) is None:
    raise SystemExit("ki-core-upstream.json has an invalid peeled commit")

repository = require_env("KI_CORE_REPOSITORY", re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))
workflow = require_env("KI_CORE_WORKFLOW", re.compile(r"[A-Za-z0-9_.-]+\.ya?ml"))
run_id = require_env("KI_CORE_RUN_ID", re.compile(r"[1-9]\d*"))
head_sha = require_env("KI_CORE_HEAD_SHA", sha_pattern)

tag = os.environ.get("KI_CORE_TAG", "")
release_commit = os.environ.get("KI_CORE_RELEASE_COMMIT", "")
if source_type == "stable":
    if repository != "xlihub/Ki-Core":
        raise SystemExit("Stable Ki-Core releases must use repository xlihub/Ki-Core")
    if workflow != "release.yml":
        raise SystemExit("Stable Ki-Core releases must use workflow release.yml")
    if tag != f"ki-core-v{version}":
        raise SystemExit("KI_CORE_TAG must use ki-core-vX.Y.Z and match ki-core-version.txt")
    if sha_pattern.fullmatch(release_commit) is None:
        raise SystemExit("KI_CORE_RELEASE_COMMIT must be a full lowercase commit SHA")
    if release_commit != head_sha:
        raise SystemExit("Stable release commit must match the workflow head SHA")
else:
    if workflow != "build-manual.yml":
        raise SystemExit("Candidate Ki-Core artifacts must use workflow build-manual.yml")
    if tag or release_commit:
        raise SystemExit("Candidate artifacts cannot claim a stable tag or release commit")

platforms = {}
for platform, (target, executable, suffix) in platform_contract.items():
    archive_name = f"ki-core-v{version}-{target}{suffix}"
    archive_path = assets_dir / archive_name
    if archive_path.is_file():
        platforms[platform] = {
            "target": target,
            "archive": archive_name,
            "executable": executable,
            "sha256": sha256(archive_path),
        }

if source_type == "stable" and list(platforms) != list(platform_contract):
    raise SystemExit("Stable release manifest requires all six canonical platform archives")
if source_type == "candidate" and len(platforms) != 1:
    raise SystemExit("Candidate release manifest requires exactly one canonical platform archive")

manifest_name = "ki-core-release.json" if source_type == "stable" else "ki-core-candidate.json"
manifest = {
    "schemaVersion": 1,
    "release": {
        "type": source_type,
        "repository": repository,
        "workflow": workflow,
        "runId": run_id,
        "headSha": head_sha,
    },
    "product": {
        "name": "Ki-Core",
        "version": version,
        "tag": tag or None,
        "releaseCommit": release_commit or None,
    },
    "upstream": {
        "repository": upstream["repository"],
        "tag": upstream["tag"],
        "peeledCommit": upstream["peeledCommit"],
    },
    "platforms": platforms,
}
manifest_path = assets_dir / manifest_name
atomic_json(manifest_path, manifest)

checksum_paths = [assets_dir / entry["archive"] for entry in platforms.values()]
checksum_paths.append(manifest_path)
checksum_lines = [f"{sha256(path)}  {path.name}" for path in sorted(checksum_paths, key=lambda item: item.name)]
checksum_path = assets_dir / "ki-core-checksums.txt"
with tempfile.NamedTemporaryFile("w", dir=assets_dir, delete=False) as handle:
    handle.write("\n".join(checksum_lines) + "\n")
    temporary_checksum_path = pathlib.Path(handle.name)
temporary_checksum_path.replace(checksum_path)

print(f"Built {source_type} Ki-Core release manifest for {len(platforms)} platform(s)")
PY
