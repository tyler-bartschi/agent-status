#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/Agent Status.app"
CONTENTS="$APP/Contents"

cd "$ROOT"

# Some Command Line Tools installations retain an older compatible SDK beside
# a newer default SDK that does not match the selected Swift compiler.
if [ -z "${SDKROOT:-}" ] &&
   [ "$(xcode-select -p 2>/dev/null || true)" = "/Library/Developer/CommandLineTools" ] &&
   [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]; then
    SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
    export SDKROOT
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp ".build/release/AgentStatusApp" "$CONTENTS/MacOS/AgentStatusApp"
cp "Resources/Info.plist" "$CONTENTS/Info.plist"
if [ -d ".build/release/AgentStatus_AgentStatusApp.bundle" ]; then
    cp -R ".build/release/AgentStatus_AgentStatusApp.bundle" "$CONTENTS/Resources/"
fi
codesign --force --sign - "$APP"

echo "Created $APP"
