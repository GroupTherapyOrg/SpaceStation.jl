# Changelog

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
