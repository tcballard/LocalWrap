#!/usr/bin/env bash
set -euo pipefail

OUTPUT="${1:?usage: render_homebrew_cask.sh OUTPUT VERSION SHA256}"
VERSION="${2:?usage: render_homebrew_cask.sh OUTPUT VERSION SHA256}"
SHA256="${3:?usage: render_homebrew_cask.sh OUTPUT VERSION SHA256}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]] \
  || { echo "error: invalid version: $VERSION" >&2; exit 2; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "error: SHA-256 must be 64 lowercase hexadecimal characters" >&2; exit 2; }

mkdir -p "$(dirname "$OUTPUT")"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA256/g" >"$OUTPUT" <<'RUBY'
cask "localwrap" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/tcballard/LocalWrap/releases/download/v#{version}/LocalWrap-#{version}-universal.dmg"
  name "LocalWrap"
  desc "Unsigned pre-release cockpit for localhost development projects"
  homepage "https://github.com/tcballard/LocalWrap"

  depends_on macos: :sequoia

  app "LocalWrap.app"

  zap trash: [
    "~/Library/Application Support/LocalWrapNative",
    "~/Library/Preferences/com.localwrap.app.plist",
    "~/Library/Saved Application State/com.localwrap.app.savedState",
  ]
end
RUBY
