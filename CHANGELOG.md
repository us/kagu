# Changelog

## [0.2.6](https://github.com/us/kagu/compare/v0.2.5...v0.2.6) (2026-10-31)


### Features

* give a default-named recording a title from its summary ([e3d8ba0](https://github.com/us/kagu/commit/e3d8ba0a029b0aac64f69862892bbb49025a15e3))
* name the other speaker in a transcript ([0cd3fff](https://github.com/us/kagu/commit/0cd3fff9dbd4a5b4e49bd8eddabce1f310d411e5))
* replace a misheard word everywhere in a transcript ([84f1374](https://github.com/us/kagu/commit/84f1374320cfd1fdfb048e5044acf638865bb1be))
* summary, decisions and action items made on this Mac ([2045de6](https://github.com/us/kagu/commit/2045de6a742c39571291d1346ec23ca71c8a6986))


### Bug Fixes

* build the summary with the macOS 26 SDK too ([729dc3f](https://github.com/us/kagu/commit/729dc3f0cbe4770885195a1dad12717bfbf2c575))
* split a time stamp sum that timed out the type checker on CI ([291fb7a](https://github.com/us/kagu/commit/291fb7a26d08131eca2e920e3f7e4fe63e002c2b))

## [0.2.5](https://github.com/us/kagu/compare/v0.2.4...v0.2.5) (2026-10-28)


### Features

* watch for calls with a small helper so Kagu can stay closed ([6b6501a](https://github.com/us/kagu/commit/6b6501a60f15a19075e85b4f41d31895ae7000f1))

## [0.2.4](https://github.com/us/kagu/compare/v0.2.3...v0.2.4) (2026-10-28)


### Features

* open at login so calls are noticed without opening Kagu ([64c5571](https://github.com/us/kagu/commit/64c55711febda7789ce9cb0ae34a71eb1d263926))

## [0.2.3](https://github.com/us/kagu/compare/v0.2.2...v0.2.3) (2026-10-28)


### Features

* playback speed, follow along, undo trash and a menu bar timer ([bc18e7b](https://github.com/us/kagu/commit/bc18e7b41071ea0ab045e7b42ce0dc1b6b82bd3a))

## [0.2.2](https://github.com/us/kagu/compare/v0.2.1...v0.2.2) (2026-10-28)


### Features

* import audio files (from the phone) into the library ([d641f5d](https://github.com/us/kagu/commit/d641f5d54998a56b016b63481af5bc6bc6bf8fb2))
* record raw audio at 16 kHz and set disk space aside while recording ([bf18b96](https://github.com/us/kagu/commit/bf18b96e908efa62af10cdf0b2f83192785675e9))
* save recordings as mono 16 kHz audio, about half the size ([b485c96](https://github.com/us/kagu/commit/b485c9687a5e20ee3575fd499e5f250dbafaee6c))


### Bug Fixes

* keep recording when the disk fills, in the space set aside ([9e2c063](https://github.com/us/kagu/commit/9e2c0633baf18b8398ac89d2f948e4f9c19dc312))
* save before the disk fills and notify when a recording stops ([8445a8f](https://github.com/us/kagu/commit/8445a8fb062d187e45fa2bfb334434f646b0bf66))

## [0.2.1](https://github.com/us/kagu/compare/v0.2.0...v0.2.1) (2026-10-27)


### Features

* notice calls, offer to record them and to stop when they end ([c40d9cf](https://github.com/us/kagu/commit/c40d9cf52046ff2b477f7a2505780737c948552e))
* row menu with rename and Finder tags, rename while transcribing ([e5852c2](https://github.com/us/kagu/commit/e5852c22b29be57340ce996aaef1e4054868f7a3))
* update itself with Sparkle, never during a recording ([e2feb61](https://github.com/us/kagu/commit/e2feb6147f00f11d845b0704e21d504727d5b154))


### Bug Fixes

* show the recording title as text, edit it in place ([b5291c2](https://github.com/us/kagu/commit/b5291c29e8facdf8798d64c319c339ba1ae5ab1e))
* take speakers and order from the two tracks ([82195a4](https://github.com/us/kagu/commit/82195a49719def9227c31d99234bca91d7c5333c))
