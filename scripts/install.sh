#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL_ROOT=${AGENT_STATUS_INSTALL_DIR:-"$HOME/Applications"}
SOURCE_APP="$ROOT/Agent Status.app"
INSTALLED_APP="$INSTALL_ROOT/Agent Status.app"
INSTALL_HOOKS=1
LAUNCH_APP=1

usage() {
    echo "Usage: $0 [--no-hooks] [--no-launch] [--install-dir DIRECTORY]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-hooks)
            INSTALL_HOOKS=0
            ;;
        --no-launch)
            LAUNCH_APP=0
            ;;
        --install-dir)
            shift
            [ "$#" -gt 0 ] || { usage; exit 2; }
            INSTALL_ROOT=$1
            INSTALLED_APP="$INSTALL_ROOT/Agent Status.app"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
    shift
done

command -v swift >/dev/null 2>&1 || {
    echo "error: Swift is required. Install Xcode or the Command Line Tools." >&2
    exit 1
}
if [ "$INSTALL_HOOKS" -eq 1 ]; then
    command -v python3 >/dev/null 2>&1 || {
        echo "error: Python 3 is required to configure provider hooks." >&2
        exit 1
    }
fi

"$ROOT/scripts/bundle.sh"

mkdir -p "$INSTALL_ROOT"
if pgrep -x AgentStatusApp >/dev/null 2>&1; then
    pkill -x AgentStatusApp || true
fi
rm -rf "$INSTALLED_APP"
/usr/bin/ditto "$SOURCE_APP" "$INSTALLED_APP"

if [ "$INSTALL_HOOKS" -eq 1 ]; then
    HOOK_SOURCE=$(
        find "$INSTALLED_APP/Contents/Resources" \
            -type f -name agent-status-hook.py -print -quit
    )
    [ -n "$HOOK_SOURCE" ] || {
        echo "error: bundled provider hook was not found" >&2
        exit 1
    }
    python3 "$ROOT/scripts/configure-hooks.py" install --hook "$HOOK_SOURCE"
fi

if [ "$LAUNCH_APP" -eq 1 ]; then
    /usr/bin/open "$INSTALLED_APP"
fi

echo "Installed Agent Status at: $INSTALLED_APP"
if [ "$INSTALL_HOOKS" -eq 1 ]; then
    echo "Codex and Claude Code hooks installed."
    echo "Open /hooks in Codex once to review and trust the Agent Status hooks."
fi
