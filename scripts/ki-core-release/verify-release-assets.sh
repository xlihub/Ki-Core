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

python3 - \
    "$source_type" \
    "$assets_dir" \
    "$repo_root/ki-core-version.txt" \
    "$repo_root/ki-core-upstream.json" <<'PY'
import hashlib
import json
import pathlib
import re
import stat
import sys
import tarfile
import zipfile

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
sha40_pattern = re.compile(r"[0-9a-f]{40}")
sha256_pattern = re.compile(r"[0-9a-f]{64}")
semver_pattern = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"Release asset set does not match the manifest: {error}")
    return digest.hexdigest()


def validate_archive(path: pathlib.Path, executable: str) -> None:
    if path.name.endswith(".tar.gz"):
        try:
            with tarfile.open(path, "r:gz") as archive:
                members = archive.getmembers()
        except (OSError, tarfile.TarError) as error:
            fail(f"Invalid release archive {path.name}: {error}")
        if len(members) != 1 or members[0].name != executable or not members[0].isfile():
            fail(f"Archive {path.name} must contain exactly one regular executable named {executable}")
    elif path.name.endswith(".zip"):
        try:
            with zipfile.ZipFile(path) as archive:
                members = archive.infolist()
        except (OSError, zipfile.BadZipFile) as error:
            fail(f"Invalid release archive {path.name}: {error}")
        unix_mode = members[0].external_attr >> 16 if len(members) == 1 else 0
        is_link = bool(unix_mode and stat.S_ISLNK(unix_mode))
        if len(members) != 1 or members[0].filename != executable or members[0].is_dir() or is_link:
            fail(f"Archive {path.name} must contain exactly one regular executable named {executable}")
    else:
        fail(f"Unsupported release archive type: {path.name}")


if not assets_dir.is_dir():
    fail(f"Release assets directory does not exist: {assets_dir}")

manifest_name = "ki-core-release.json" if source_type == "stable" else "ki-core-candidate.json"
manifest_path = assets_dir / manifest_name
checksum_path = assets_dir / "ki-core-checksums.txt"
try:
    manifest = json.loads(manifest_path.read_text())
except (OSError, json.JSONDecodeError) as error:
    fail(f"Invalid {manifest_name}: {error}")

if set(manifest) != {"schemaVersion", "release", "product", "upstream", "platforms"}:
    fail("Release manifest has unexpected or missing top-level fields")
if manifest.get("schemaVersion") != 1:
    fail("Release manifest schemaVersion must be 1")

release = manifest.get("release")
product = manifest.get("product")
upstream = manifest.get("upstream")
platforms = manifest.get("platforms")
if not all(isinstance(value, dict) for value in (release, product, upstream, platforms)):
    fail("Release manifest objects are malformed")

expected_release_keys = {"type", "repository", "workflow", "runId", "headSha"}
if set(release) != expected_release_keys or release.get("type") != source_type:
    fail("Release source identity is malformed")
if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", str(release.get("repository"))) is None:
    fail("Release repository identity is malformed")
expected_workflow = "release.yml" if source_type == "stable" else "build-manual.yml"
if release.get("workflow") != expected_workflow:
    fail(f"Release workflow identity must be {expected_workflow}")
if re.fullmatch(r"[1-9]\d*", str(release.get("runId"))) is None:
    fail("Release run ID is malformed")
if sha40_pattern.fullmatch(str(release.get("headSha"))) is None:
    fail("Release head SHA is malformed")

version = product.get("version")
if set(product) != {"name", "version", "tag", "releaseCommit"} or product.get("name") != "Ki-Core":
    fail("Ki-Core product identity is malformed")
if not isinstance(version, str) or semver_pattern.fullmatch(version) is None:
    fail("Ki-Core product version is malformed")
if version != version_file.read_text().strip():
    fail("Ki-Core product version does not match ki-core-version.txt")
if source_type == "stable":
    if release.get("repository") != "xlihub/Ki-Core":
        fail("Stable release repository must be xlihub/Ki-Core")
    if product.get("tag") != f"ki-core-v{version}":
        fail("Stable release tag does not match the Ki-Core version")
    if product.get("releaseCommit") != release.get("headSha"):
        fail("Stable release commit does not match the workflow head SHA")
elif product.get("tag") is not None or product.get("releaseCommit") is not None:
    fail("Candidate artifacts cannot claim stable product provenance")

expected_upstream = json.loads(upstream_file.read_text())
if re.fullmatch(r"v\d+\.\d+\.\d+", str(expected_upstream.get("tag"))) is None:
    fail("ki-core-upstream.json has an invalid tag")
if sha40_pattern.fullmatch(str(expected_upstream.get("peeledCommit"))) is None:
    fail("ki-core-upstream.json has an invalid peeled commit")
if upstream != {
    "repository": expected_upstream.get("repository"),
    "tag": expected_upstream.get("tag"),
    "peeledCommit": expected_upstream.get("peeledCommit"),
}:
    fail("AionCore provenance does not match ki-core-upstream.json")

expected_platforms = list(platform_contract)
actual_platforms = list(platforms)
if source_type == "stable" and actual_platforms != expected_platforms:
    fail("Stable release manifest must contain the six canonical platforms in order")
if source_type == "candidate" and (len(actual_platforms) != 1 or actual_platforms[0] not in platform_contract):
    fail("Candidate release manifest must contain exactly one canonical platform")

archive_names = []
for platform, entry in platforms.items():
    if not isinstance(entry, dict) or set(entry) != {"target", "archive", "executable", "sha256"}:
        fail(f"Platform metadata is malformed: {platform}")
    target, executable, suffix = platform_contract[platform]
    expected_archive = f"ki-core-v{version}-{target}{suffix}"
    if entry.get("target") != target or entry.get("archive") != expected_archive or entry.get("executable") != executable:
        fail(f"Platform contract mismatch: {platform}")
    if sha256_pattern.fullmatch(str(entry.get("sha256"))) is None:
        fail(f"Platform checksum is malformed: {platform}")
    archive_names.append(expected_archive)
if len(archive_names) != len(set(archive_names)):
    fail("Release archive names must be unique")

try:
    checksum_lines = checksum_path.read_text().splitlines()
except OSError as error:
    fail(f"Invalid ki-core-checksums.txt: {error}")
checksums = {}
for line in checksum_lines:
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
    if match is None:
        fail(f"Malformed checksum entry: {line}")
    digest, name = match.groups()
    if name in checksums:
        fail(f"Duplicate checksum entry: {name}")
    checksums[name] = digest

expected_checksum_names = set(archive_names + [manifest_name])
if set(checksums) != expected_checksum_names:
    fail("Checksum file does not cover exactly the manifest and release archives")

allowed_files = expected_checksum_names | {"ki-core-checksums.txt"}
for path in assets_dir.iterdir():
    if path.is_symlink() or not path.is_file() or path.name not in allowed_files:
        fail(f"Unexpected release asset: {path.name}")
if {path.name for path in assets_dir.iterdir()} != allowed_files:
    fail("Release asset set does not match the manifest")

for name, expected_digest in checksums.items():
    actual_digest = sha256(assets_dir / name)
    if actual_digest != expected_digest:
        fail(f"Checksum mismatch for {name}")

for platform, entry in platforms.items():
    archive_path = assets_dir / entry["archive"]
    if sha256(archive_path) != entry["sha256"]:
        fail(f"Manifest checksum mismatch for {platform}")
    validate_archive(archive_path, entry["executable"])

print(f"Verified {source_type} Ki-Core release assets for {len(platforms)} platform(s)")
PY
