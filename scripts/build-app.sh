#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Agent Island.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
    export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/swift-module-cache"

cd "$ROOT_DIR"

cp "$ROOT_DIR/assets/codex-pet-transparent.png" "$ROOT_DIR/macos/Sources/AgentIsland/Resources/codex-pet.png"
cp "$ROOT_DIR/assets/claude-mascot-transparent.png" "$ROOT_DIR/macos/Sources/AgentIsland/Resources/claude-mascot.png"

cargo build --release --manifest-path "$ROOT_DIR/agent-core/Cargo.toml"
SWIFTPM_SANDBOX_ARGUMENTS=()
if [[ "${AGENT_ISLAND_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    SWIFTPM_SANDBOX_ARGUMENTS+=(--disable-sandbox)
fi
swift build \
    "${SWIFTPM_SANDBOX_ARGUMENTS[@]}" \
    -c release \
    --scratch-path "$ROOT_DIR/.build" \
    --cache-path "$ROOT_DIR/.build/swiftpm-cache"

if [[ "$APP_DIR" != "$ROOT_DIR/dist/Agent Island.app" ]]; then
    echo "Refusing to replace an unexpected path: $APP_DIR" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR"

cp "$ROOT_DIR/.build/release/AgentIsland" "$MACOS_DIR/AgentIsland"
cp "$ROOT_DIR/agent-core/target/release/agent-core" "$HELPERS_DIR/agent-core"
cp "$ROOT_DIR/macos/Info.plist" "$CONTENTS_DIR/Info.plist"

RESOURCE_BUNDLE="$ROOT_DIR/.build/release/AgentIsland_AgentIsland.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

ICONSET_DIR="$ROOT_DIR/.build/AgentIsland.iconset"
ICON_FILE="$ROOT_DIR/.build/AgentIsland.icns"
mkdir -p "$ICONSET_DIR"
xcrun swift \
    "$ROOT_DIR/scripts/make-app-icon.swift" \
    "$ROOT_DIR/assets/agent-island-app-icon.png" \
    "$ICONSET_DIR" \
    "$ICON_FILE"
cp "$ICON_FILE" "$RESOURCES_DIR/AgentIsland.icns"

chmod +x "$MACOS_DIR/AgentIsland" "$HELPERS_DIR/agent-core"
xattr -cr "$APP_DIR"
# Sign with a local identity when one exists, otherwise ad-hoc.
#
# This matters for permissions, not for distribution. macOS pins Accessibility
# and audio-capture grants to the signature's designated requirement; an ad-hoc
# signature changes on every build, so every rebuild revokes them. A stable
# self-signed identity keeps the requirement constant, so a grant survives.
#
# Contributors without the certificate still get a working ad-hoc build; they
# just re-approve permissions after each rebuild. Create one with:
#   scripts/make-signing-cert.sh
SIGNING_IDENTITY="Agent Island Local"
if security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
    SIGN_AS="$SIGNING_IDENTITY"
    echo "signing as: $SIGNING_IDENTITY (stable identity, permissions persist)"
else
    SIGN_AS="-"
    echo "signing ad-hoc (no local identity; permissions reset each build)"
fi

codesign --force --sign "$SIGN_AS" --options runtime --timestamp=none "$HELPERS_DIR/agent-core"
codesign --force --sign "$SIGN_AS" --options runtime --timestamp=none "$APP_DIR"

echo "$APP_DIR"
