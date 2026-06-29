#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL_ROOT=${AGENT_STATUS_INSTALL_DIR:-"$HOME/Applications"}
INSTALLED_APP="$INSTALL_ROOT/Agent Status.app"

if pgrep -x AgentStatusApp >/dev/null 2>&1; then
    pkill -x AgentStatusApp || true
fi

python3 "$ROOT/scripts/configure-hooks.py" uninstall
rm -rf "$INSTALLED_APP"
rm -f "$HOME/Library/Application Support/AgentStatus/Hooks/agent-status-hook.py"

echo "Removed Agent Status and its provider hooks."
