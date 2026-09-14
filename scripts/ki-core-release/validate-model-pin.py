"""校验 Core → Ki-Model → aionrs 来源链，不访问网络或改写依赖。"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib


CRATES = ("aion-agent", "aion-providers", "aion-types", "aion-protocol", "aion-config", "aion-mcp")
REPOSITORY = "https://github.com/xlihub/Ki-Model.git"
SHA = re.compile(r"[0-9a-f]{40}")
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_tag(repository, tag, commit):
    result = subprocess.run(
        ["git", "ls-remote", "--tags", repository, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
        capture_output=True, text=True, check=True, timeout=60,
    )
    refs = {ref: sha for sha, ref in (line.split() for line in result.stdout.splitlines())}
    actual = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
    require(actual == commit, f"Published SDK source tag does not match provenance: {tag}")


def validate(root, require_release):
    pin = json.loads((root / "ki-core-model.json").read_text())
    require(pin.get("schemaVersion") == 1 and pin.get("repository") == "xlihub/Ki-Model", "Invalid SDK provenance")
    commit = pin.get("peeledCommit", "")
    tag = pin.get("targetTag", "")
    require(SHA.fullmatch(commit), "SDK peeledCommit must be a full commit")
    require(re.fullmatch("ki-model-v" + VERSION, tag), "SDK targetTag must use ki-model-vX.Y.Z")
    require(type(pin.get("releaseVerified")) is bool, "releaseVerified must be boolean")
    require(re.fullmatch(VERSION, pin.get("packageVersion", "")), "Invalid SDK packageVersion")
    upstream = pin.get("upstream", {})
    require(upstream.get("repository") == "iOfficeAI/aionrs", "Invalid SDK upstream repository")
    require(re.fullmatch("v" + VERSION, upstream.get("tag", "")), "Invalid SDK upstream tag")
    require(SHA.fullmatch(upstream.get("peeledCommit", "")), "Invalid SDK upstream commit")

    manifest = tomllib.loads((root / "Cargo.toml").read_text())
    dependencies = manifest["workspace"]["dependencies"]
    accepted = dependencies[CRATES[0]]
    for name in CRATES:
        dependency = dependencies.get(name, {})
        require(dependency.get("git") == REPOSITORY, f"{name} must use the accepted Ki-Model repository")
        require(set(dependency) in ({"git", "tag"}, {"git", "rev"}), f"{name} cannot use a version, path, branch or extra source")
        require(dependency.get("rev") == commit or dependency.get("tag") == tag, f"{name} must use the accepted SDK pin")
        require(dependency == accepted, f"{name} must use the same SDK source as the other five crates")
    for path in [root / "Cargo.toml", *sorted((root / "crates").glob("*/Cargo.toml"))]:
        data = tomllib.loads(path.read_text())
        require(not data.get("patch") and not data.get("replace"), f"{path.name}: patch/replace cannot bypass the SDK pin")
        if path != root / "Cargo.toml":
            for section in ("dependencies", "dev-dependencies", "build-dependencies"):
                for name in CRATES:
                    entry = data.get(section, {}).get(name)
                    require(entry is None or entry.get("workspace") is True, f"{path}: {name} must inherit the SDK workspace pin")

    selector = f"tag={tag}" if "tag" in accepted else f"rev={commit}"
    expected_source = f"git+{REPOSITORY}?{selector}#{commit}"
    packages = tomllib.loads((root / "Cargo.lock").read_text())["package"]
    sdk = [package for package in packages if package["name"].startswith("aion-") or package["name"] == "workspace-hack"]
    names = [package["name"] for package in sdk]
    require(len(names) == len(set(names)), "Duplicate SDK package types")
    require(set(CRATES) <= set(names), "Missing SDK package in Cargo.lock")
    for package in sdk:
        require(package.get("source") == expected_source, f"{package['name']}: mismatched locked SDK source")
        if package["name"] in CRATES:
            require(package["version"] == pin["packageVersion"], f"{package['name']}: preserve upstream package version")
    if require_release:
        require(pin["releaseVerified"], "Ki-Model SDK is not release-verified; Core release is blocked")
        verify_tag(REPOSITORY, tag, commit)
        verify_tag("https://github.com/iOfficeAI/aionrs.git", upstream["tag"], upstream["peeledCommit"])
    print(f"Ki-Model pin valid: {commit} (target {tag}, releaseVerified={pin['releaseVerified']})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--require-release", action="store_true")
    args = parser.parse_args()
    try:
        validate(args.root, args.require_release)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
