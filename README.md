# LocalWrap for macOS

LocalWrap is a native macOS cockpit for local development projects. Save local
commands, start and monitor processes, diagnose configuration problems, preview
loopback URLs, and resume dependency-aware workspaces without terminal juggling.

## Requirements

- macOS 15 or newer
- Xcode 26 or newer
- XcodeGen 2.44.1 or newer

## Build and run

```bash
brew install xcodegen
./script/build_and_run.sh --verify
```

Debug builds are named `LocalWrapMac`, use bundle ID
`com.localwrap.app.native`, and store data in
`~/Library/Application Support/LocalWrapNative-Debug`.

## Test

```bash
xcodegen generate --spec project.yml --project .
xcodebuild -project LocalWrap.xcodeproj -scheme LocalWrapMac \
  -destination 'platform=macOS' -derivedDataPath .build/LocalWrapMac test
./script/soak_native_macos.sh
./script/verify_native_macos_release.sh
```

The Release product is the universal `LocalWrap.app`, bundle ID
`com.localwrap.app`, with storage in
`~/Library/Application Support/LocalWrapNative`. First launch validates and
copies compatible data from the former Electron LocalWrap store without editing
the source file.

## Install with Homebrew

Signed releases are published through the `tcballard/homebrew-tap` Cask:

```bash
brew tap tcballard/tap
brew install --cask localwrap
```

After notarization succeeds, the release workflow publishes the GitHub Release
and updates the Cask with the exact DMG version and SHA-256. The repository
secret `HOMEBREW_TAP_TOKEN` must have Contents read/write access to
`tcballard/homebrew-tap`.

## Signed distribution

`./script/release_native_macos.sh` archives, Developer ID-signs, packages,
notarizes, staples, Gatekeeper-verifies, and checksums the universal DMG. It
fails closed unless the required Apple signing and notarization credentials are
available.
