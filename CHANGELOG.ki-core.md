# Ki-Core Changelog

This changelog records Ki-Core product releases. Runtime changes inherited from
AionCore remain in [CHANGELOG.md](CHANGELOG.md) and are linked through the
version mapping in [ki-core-versions.json](ki-core-versions.json).

## [0.2.0](https://github.com/xlihub/Ki-Core/compare/ki-core-v0.1.0...ki-core-v0.2.0) (2026-08-06)


### Features

* **agent:** multimodal prompt — native image/audio content blocks gated by promptCapabilities ([#774](https://github.com/xlihub/Ki-Core/issues/774)) ([5a78a0b](https://github.com/xlihub/Ki-Core/commit/5a78a0b2722edcce9f979d3f06c4461577f9e574))
* **release:** add Ki-Core product metadata contract ([eb4c2ca](https://github.com/xlihub/Ki-Core/commit/eb4c2ca6bebf4488beb928d23c4fc3876711b0cb))
* **release:** add manual Release Please dispatch ([811cde9](https://github.com/xlihub/Ki-Core/commit/811cde941ecf899f488ab23b956d352f1de91fb7))
* **release:** adopt Ki-Core Release Please semantics ([749dfc4](https://github.com/xlihub/Ki-Core/commit/749dfc46546af382ed27aac69c7f1c03dca7038a))
* **release:** establish independent Ki-Core releases ([51cca80](https://github.com/xlihub/Ki-Core/commit/51cca8065dc07f020619b9658988b2bd8213bc22))
* **release:** secure Ki-Core publication pipeline ([206e535](https://github.com/xlihub/Ki-Core/commit/206e53527178e63bcbbf5ce5d5e58b4109fef5c4))
* **team:** add read-only mailbox/task activity API and real-time events ([#740](https://github.com/xlihub/Ki-Core/issues/740)) ([f86c053](https://github.com/xlihub/Ki-Core/commit/f86c053eded3e04f5139dadeb3bdb9bae94c9c3b))


### Bug Fixes

* **release:** harden draft publication lifecycle ([fb9383f](https://github.com/xlihub/Ki-Core/commit/fb9383f290f1917cab1b1c9f7c9621a1f6e04b7d))
* **release:** validate generated manifests efficiently ([81b66ca](https://github.com/xlihub/Ki-Core/commit/81b66ca7b04406d787360559e7269e7402f8e3d5))
* **release:** validate map updates against remote tags ([3e43d49](https://github.com/xlihub/Ki-Core/commit/3e43d4959157641b1572f550e02ccf86839b8b71))
* **release:** validate map updates against remote tags ([dec8a96](https://github.com/xlihub/Ki-Core/commit/dec8a964229ad979659ba28f0019fb28a03e6e18))
* **release:** validate remote tags without local refs ([c6330ca](https://github.com/xlihub/Ki-Core/commit/c6330ca34ab8396b8e1d7a4ee356ad15336a8a89))

## 0.1.0 (2026-08-06)

### Upstream baseline

- Based on AionCore `v0.1.59` (`815e61ed9bbe942339347dc1e69ddce176cded76`).

### Ki-Core product

- Establishes independent Ki-Core versions, tags, release assets, and the
  Ki-Core-to-AionCore version mapping.
