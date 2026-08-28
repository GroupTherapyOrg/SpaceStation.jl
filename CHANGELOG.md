# Changelog

## [0.4.8](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.4.7...v0.4.8) (2026-08-28)


### Bug Fixes

* open a window on Windows — WebView2 had nowhere to write its data ([#56](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/56)) ([bfc71d8](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/bfc71d8402e8ae62a52e1d7fcf20c356cd81ecdd))

## [0.4.7](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.4.6...v0.4.7) (2026-08-26)


### Bug Fixes

* shift the deck tabs into the traffic lights' gap in fullscreen, and show a pointer on tabs ([#53](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/53)) ([ef76598](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/ef765988fba63f62ee3f16e38ade01e67e06b83d))

## [0.4.6](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.4.5...v0.4.6) (2026-08-26)


### Bug Fixes

* stop Pkg.Apps warning about PATH on every bootstrap ([#51](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/51)) ([ef9998a](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/ef9998a89d14c5959ef73c9cb9ea2cef48ed274d))

## [0.4.5](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.4.4...v0.4.5) (2026-08-25)


### Bug Fixes

* window dragging via a native bridge, and recreate stale WKWebView scrollers ([#49](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/49)) ([19ba976](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/19ba9765075db7e721de3e543cbb1e9916e09db7))

## [0.4.4](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.4.3...v0.4.4) (2026-08-25)


### Bug Fixes

* fit the window to the screen and make shell pages draggable ([#47](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/47)) ([b7bdc28](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/b7bdc28fcab63382ceb58dce325c4fee03acf3f7))

## [0.4.3](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.4.2...v0.4.3) (2026-08-25)


### Bug Fixes

* every Launch Station control is now the one-click action it names ([#45](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/45)) ([413cf5e](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/413cf5ebbe6c23fdb8d6077eb9d9426fab62b439))
* theme toggle must not blank views or lose scrollbars in the desktop app ([#44](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/44)) ([535d88a](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/535d88ac3144c4b84e10cb33953ffa247a9f3552))

## [0.4.2](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.4.1...v0.4.2) (2026-08-25)


### Bug Fixes

* make the Julia update badge show what it will do ([#41](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/41)) ([6a920e4](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/6a920e4ea4e44429418aecc74f96c408b8e9e1c6))

## [0.4.1](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.4.0...v0.4.1) (2026-08-25)


### Bug Fixes

* give release installer builds their own concurrency lane ([#38](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/38)) ([07c59bd](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/07c59bd191c210ede8ce2e1f5075cfe6d761958d))
* installers must contain SpaceStation, not the platform-suffixed name ([#37](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/37)) ([888752d](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/888752dc201d685d9b4d03ca6ecd82a2543c687e))

## [0.4.0](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.3.1...v0.4.0) (2026-08-25)


### Features

* SpaceStation desktop app — native shell, Launch Station, release installers ([#34](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/34)) ([2256740](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/225674040d0ab27966391440c546c196bee1992c))

## [0.3.1](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.3.0...v0.3.1) (2026-08-24)


### Bug Fixes

* repair xterm scroll state when a hidden terminal tab is revealed ([#32](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/32)) ([e90a860](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/e90a860b819544c57d3239216179ba598af5308f))

## [0.3.0](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.2.7...v0.3.0) (2026-08-22)


### Features

* SSH workspace robustness, Safe preview fixes, and .plutojl support ([#28](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/28)) ([96aef78](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/96aef78364308231dcfab65e6bb3aabb517e9664))

## [0.2.7](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.2.6...v0.2.7) (2026-08-18)


### Bug Fixes

* build the folder picker's paths on the server, not in the browser ([#26](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/26)) ([e6c1718](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/e6c1718b2cb8170c0d937d9f4184eb8d65b2266e))
* list the workspace sidebar breadth-first and load it folder by folder ([#24](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/24)) ([77e0718](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/77e071810fd42fe6e96fb1b45022f5e806684f8c))

## [0.2.6](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.2.5...v0.2.6) (2026-07-13)


### Bug Fixes

* avoid duplicate terminal on refresh ([#22](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/22)) ([d78dcee](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/d78dcee555f75c7fa7fb1a781ba17c3516a056b3))

## [0.2.5](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.2.4...v0.2.5) (2026-07-13)


### Bug Fixes

* terminal paste duplication and permission prompts ([#20](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/20)) ([03ba583](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/03ba583a6a9189fc3ab339a060e61f200285b6b6))

## [0.2.4](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.2.3...v0.2.4) (2026-07-10)


### Bug Fixes

* harden remote, collab, and terminal workflows ([#18](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/18)) ([f8275e1](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/f8275e10a9c1b7999965ad7d3045f483ca0104c2))

## [0.2.3](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.2.2...v0.2.3) (2026-07-07)


### Bug Fixes

* collab run reported "ok" when Safe Preview blocked execution entirely ([#16](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/16)) ([9f8dccc](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/9f8dccc1212a1d6f232cb5a55f152c506b1f9235))

## [0.2.2](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.2.1...v0.2.2) (2026-07-07)


### Bug Fixes

* merge upstream Pluto.jl v1.0.3 (CodeMirror 2002.0.8, lezer-julia 1.2 compat, editor polish) ([b99f582](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/b99f58217366fce9a6ab8bf40b1e5b6374dd6a4c))
* merge upstream Pluto.jl v1.0.3 (CodeMirror 2002.0.8, lezer-julia 1.2, editor polish) ([c36393f](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/c36393f8c223b12222ef500c35c43b253b683c89))
* unsuppressible in-page confirmation for the hub's destructive actions ([#12](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/12)) ([e3616f0](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/e3616f08750a8dfae1d64711d40b508296c88aed))
* Windows notebook saves failed while the file watcher holds the file ([d150762](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/d1507621924bb29428295a9e03d65b1305bbfdb5))

## [0.2.1](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.2.0...v0.2.1) (2026-07-06)


### Bug Fixes

* registration notes must say 'changelog'/'breaking' for AutoMerge ([#9](https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/9)) ([c115b08](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/c115b0833d8172a3856c845943bc071b6dd8dc2a))

## [0.2.0](https://github.com/GroupTherapyOrg/SpaceStation.jl/compare/v0.1.0...v0.2.0) (2026-07-06)


### Features

* automate General-registry releases with release-please ([afe2169](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/afe21695d7b2d32cf949f345539b7548a664259e))
* automate General-registry releases with release-please ([10523e0](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/10523e00ca1a81c3154fec91878be1b2bc6e86b0))


### Bug Fixes

* bootstrap the secret cookie via / before opening /index.html in E2E ([e8f87cd](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/e8f87cda8e94bdb8d978f77ddc132648b1ba9636))
* bundler chokes on SVG fragment refs; config test misses the workspace kwarg alias ([f65398b](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/f65398b2171ccf89cc908403076b98536a5841c9))
* harden the two-file collab editing against races ([ca83e2c](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/ca83e2c5c6f7eed4a52da2a3a944f5c55a086f0e))
* harden the two-file collab editing against races ([91c6b90](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/91c6b90c3bc9894cd50f85e0b7979f2aac15d04c))
* Julia 1.10 precompile, test-suite parse errors, Bundle without PAT ([9446d45](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/9446d4523b4d3972da42d83680d930a39ee47219))
* Julia 1.10 precompile, test-suite parse errors, Bundle without PAT ([3645874](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/364587406ef944185cdc41fdbbdbd9fb66e69bfa))
* pin the open-and-run Pkg tests to autorun sessions ([a2727dd](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/a2727dd10c92a0643cbdc9653a38966820865c3b))
* run the E2E server in autorun — the lazy default breaks Safe Preview tests ([2d83104](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/2d83104b988ae6d29a40b57d07807bfce2fc988f))
* transparent PNG/ICO favicons (qlmanage had baked a white background) ([75e1450](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/75e1450984fdc392cec55891eb6d03e035632b7d))
* two more lazy-default test casualties (nested-Pluto timeout, E2E landing page) ([0fbed94](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/0fbed94612142a258fa46a3c41c231311a614ee3))
* TypeScript check errors; treat prerelease Julia as informational ([83c98a3](https://github.com/GroupTherapyOrg/SpaceStation.jl/commit/83c98a365aab5fc5f4fe63530b8961e84312a309))
