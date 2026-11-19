# Changelog

## [0.1.5](https://github.com/mateonunez/pitwall/compare/v0.1.4...v0.1.5) (2026-11-19)


### Bug Fixes

* the bottom rule gives way as a pane narrows instead of cutting the machine's figures ([44b5b32](https://github.com/mateonunez/pitwall/commit/44b5b323c9d0739a542568260288847361f43801))

## [0.1.4](https://github.com/mateonunez/pitwall/compare/v0.1.3...v0.1.4) (2026-11-19)


### Features

* a tabs layout, workspaces as tab groups on top and the machine on the panes' bottom rule ([c4c62eb](https://github.com/mateonunez/pitwall/commit/c4c62eb7229a0b65244ae362b16e3e6a4bcb7c57))


### Bug Fixes

* the machine sampler keeps its counters, so the network rate shows ([dd15efa](https://github.com/mateonunez/pitwall/commit/dd15efa749504b92d7a09f7005af0f5b1099be24))

## [0.1.3](https://github.com/mateonunez/pitwall/compare/v0.1.2...v0.1.3) (2026-11-19)


### Bug Fixes

* lanes keep their signals when hooks run outside tmux or subagents work in the background ([2db23a3](https://github.com/mateonunez/pitwall/commit/2db23a399a1de993b131790dfec5354265c49fe6))

## [0.1.2](https://github.com/mateonunez/pitwall/compare/v0.1.1...v0.1.2) (2026-11-17)


### Bug Fixes

* a window moving out of a workspace leaves no gap ([bfd85f6](https://github.com/mateonunez/pitwall/commit/bfd85f6f3a2032a95803f89cad0fa4f2419e7de9))

## [0.1.1](https://github.com/mateonunez/pitwall/compare/v0.1.0...v0.1.1) (2026-11-17)


### Features

* the board as a manager, with filter, output search, workspace views and a safe selection ([f3ffbd0](https://github.com/mateonunez/pitwall/commit/f3ffbd0499cdc4060b403592a9c2b4065357d73d))
* turn a lane urgent after ten minutes of asking, and show Needs you's count ([bc10288](https://github.com/mateonunez/pitwall/commit/bc102884b13f75a66b73b1ba7cbacc368a813fc9))
* workspaces, move lanes between them with their agents still running ([5ef9d73](https://github.com/mateonunez/pitwall/commit/5ef9d732e75871c6d5292bf9b6f41da3349f16a9))


### Performance Improvements

* redraw the board only when it changes, on a modern bash ([ded751a](https://github.com/mateonunez/pitwall/commit/ded751a6a64329a86ca954d7bb5dead55dfe1868))

## 0.1.0 (2026-11-14)


### Features

* initial release ([54f6951](https://github.com/mateonunez/pitwall/commit/54f6951379cb6af00cc8211c4a65de2e23033a76))
* report lanes to OpenTimeline, show limit resets, draw the board faster, and release with release-please ([4a53c75](https://github.com/mateonunez/pitwall/commit/4a53c75047290df08d52db1030e7b210ded09068))
* restore agents after tmux dies, with lane metrics and usage limits ([37650ac](https://github.com/mateonunez/pitwall/commit/37650ac1cd93ff5bf270f62e22a75aa2b9e6ceb5))
