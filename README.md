# Ki-Core

Ki-Core is the independently versioned core distribution used by Ki-Buddy. It
tracks a selected stable AionCore tag while keeping Ki-Core product versions,
tags, release notes, and binary archives separate from AionCore.

The current product version is stored in [`ki-core-version.txt`](ki-core-version.txt).
The corresponding AionCore tag and peeled commit are recorded in
[`ki-core-versions.json`](ki-core-versions.json). Runtime source and Cargo
versions continue to follow the mapped AionCore release.

## Release PR body contract

Release Please parses the merged release PR body before it creates the Ki-Core
tag and GitHub Release. A release PR body must preserve this structure:

```markdown
Ki-Core X.Y.Z release
---

## [X.Y.Z](release-or-compare-url)

Release notes

---
Release Please footer or maintainer notes
```

The header, release notes, and footer may be written in Chinese. Do not replace
the two `---` delimiters or the `## [X.Y.Z]` version heading with an unstructured
PR description. Ordinary feature, fix, and maintenance PRs are not subject to
this machine-readable body contract.
