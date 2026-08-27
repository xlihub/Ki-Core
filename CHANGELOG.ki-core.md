# Ki-Core Changelog

This changelog records Ki-Core product releases. Runtime changes inherited from
AionCore remain in [CHANGELOG.md](CHANGELOG.md) and are linked through the
version mapping in [ki-core-versions.json](ki-core-versions.json).

## [0.1.4](https://github.com/xlihub/Ki-Core/compare/ki-core-v0.1.3...ki-core-v0.1.4) (2026-08-27)


### Bug Fixes

* **cron:** preserve scheduled task capabilities ([95699ff](https://github.com/xlihub/Ki-Core/commit/95699ff601e18bea22d77b13c9b5cddd5742527e))
* **cron:** preserve scheduled task capabilities ([852782d](https://github.com/xlihub/Ki-Core/commit/852782d96407efd2c57461ad9b13ff4e785f96c2))

## [0.1.3](https://github.com/xlihub/Ki-Core/compare/ki-core-v0.1.2...ki-core-v0.1.3) (2026-08-25)


### Bug Fixes

* **cli:** register unindexed top-level subcommands in the capability index ([#929](https://github.com/xlihub/Ki-Core/issues/929)) ([c490161](https://github.com/xlihub/Ki-Core/commit/c490161df4ee7ab34830e81a67473d416ca78f03))
* **upstream:** sync AionCore v0.1.72 ([a319bb6](https://github.com/xlihub/Ki-Core/commit/a319bb694b8f6226a911d5481ead9ca71f964d0f))
* **upstream:** sync AionCore v0.1.72 ([7dc728c](https://github.com/xlihub/Ki-Core/commit/7dc728c9479cd9b9022b14a89c5597d61e8957c5))


### Performance Improvements

* slim auto-inject skill descriptions to the injection budget ([#930](https://github.com/xlihub/Ki-Core/issues/930)) ([9b7e4ce](https://github.com/xlihub/Ki-Core/commit/9b7e4cee9c14faabb4965bc364e3a093c1813e61))

## [0.1.2](https://github.com/xlihub/Ki-Core/compare/ki-core-v0.1.1...ki-core-v0.1.2) (2026-08-24)


### Features

* **agents:** require file upload before invoke ([ff55cde](https://github.com/xlihub/Ki-Core/commit/ff55cdeb104597b713e47e44e7734fbfa968d814))
* **agents:** require file upload before invoke ([#23](https://github.com/xlihub/Ki-Core/issues/23)) ([3925042](https://github.com/xlihub/Ki-Core/commit/3925042192702b8b30ce982e638636981f4a1406))

## [0.1.1](https://github.com/xlihub/Ki-Core/compare/ki-core-v0.1.0...ki-core-v0.1.1) (2026-08-21)


### Features

* **assistants:** add agents execution assistant ([aac8bc4](https://github.com/xlihub/Ki-Core/commit/aac8bc42904b135e5ddf72cec4c159ef1ecc9545))
* **assistants:** add agents execution assistant ([fd180d5](https://github.com/xlihub/Ki-Core/commit/fd180d522ca63bbbcaef4219364bbf8cc02ed212))


### Bug Fixes

* **release:** handle missing pending metadata file ([5d66f83](https://github.com/xlihub/Ki-Core/commit/5d66f83408e731299a8abe06173fff960c6b6655))
* **release:** handle missing pending metadata file ([1e3a86a](https://github.com/xlihub/Ki-Core/commit/1e3a86aa01fd9e278368a54a5d846a15dd2f75b6))
* **release:** support pending upstream baseline ([13c027f](https://github.com/xlihub/Ki-Core/commit/13c027f5515e674144bddf7175c8f6884940d5cf))
* **release:** support pending upstream baseline ([2553b13](https://github.com/xlihub/Ki-Core/commit/2553b1308b96b19d418d498fe81c1bb625a37cf0))

## 0.1.0 (2026-08-06)

### Upstream baseline

- Based on AionCore `v0.1.59` (`815e61ed9bbe942339347dc1e69ddce176cded76`).

### Ki-Core product

- Establishes independent Ki-Core versions, tags, release assets, and the
  Ki-Core-to-AionCore version mapping.
