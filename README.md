# Ki-Core

Ki-Core is the independently versioned core distribution used by Ki-Buddy. It
tracks a selected stable AionCore tag while keeping Ki-Core product versions,
tags, release notes, and binary archives separate from AionCore.

The current product version is stored in [`ki-core-version.txt`](ki-core-version.txt).
The published AionCore baseline is stored in
[`ki-core-upstream.json`](ki-core-upstream.json), and its release history is
recorded in [`ki-core-versions.json`](ki-core-versions.json). A sync PR records
its selected baseline in `ki-core-upstream-pending.json`; the Release Please PR
promotes that file to the published baseline and updates the version history.
The selected AionCore release records Ki-Core's upstream baseline and source
provenance. Ki-Core may maintain independent runtime, Cargo, and test changes
on top of that baseline; those changes are versioned and released as Ki-Core.

## Release PR machine contract

Release Please 解析已合并的 Release PR 正文后创建 Ki-Core tag 和 GitHub Release。
正常发布使用自动生成的 `release-please--branches--product/main--components--ki-core`
分支；恢复既有版本时才使用 `release-ki-core-vX.Y.Z` 分支。

A release PR body must preserve this structure:

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
PR description. Do not rename a release branch to an ordinary feature or fix
branch. Ordinary feature, fix, and maintenance PRs are not subject to this
machine-readable contract.

## 指定本次发布版本

当维护者选择的版本与自动计算结果不同，在普通维护 PR 的提交正文中使用
[Release Please 支持的 `Release-As` footer](https://github.com/googleapis/release-please#how-do-i-change-the-version-number)，
将 `X.Y.Z` 替换为维护者选择且尚未发布的版本：

```text
chore(release): select product version

Release-As: X.Y.Z
```

合并时保留该 footer，随后由 Release Please 重新生成版本 PR，并核验标题、正文、
`ki-core-version.txt`、manifest、changelog 和版本映射均使用目标版本。
这个 footer 只指定本次发布，不在配置中保存 `release-as`，也不改变后续 SemVer 规则。

普通版本选择提交的标题不要使用 `chore: release` 或 `chore(product/main): release`；
这两种标题会让仓库 workflow 进入创建 tag 的路径。正式 Release PR 合并后，
仍由维护者批准 `ki-core-stable` Environment，再构建六个平台产物与 checksums。
