#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/Agent Status.app"
CONTENTS="$APP/Contents"

cd "$ROOT"
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
