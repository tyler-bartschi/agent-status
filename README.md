# Agent Status

A personal macOS menu-bar app that shows the state of local Codex and Claude
Code sessions around the MacBook notch.

- Yellow rotating ring: Working
- Red pulsing beacon: Waiting for input or permission
- Green checkmark pop: Finished (shown for three seconds)

The right-side number counts sessions in the currently displayed state. Click
the notch surface to smoothly expand a list of all active sessions. Click
outside the panel to close it, or use the forget button beside a session to
clear a stale entry. A live forgotten session can reappear when it sends its
next event. When macOS Reduce Motion is enabled, indicators and panel changes
use static equivalents.

## Requirements

- macOS 13 or newer
- Swift 6 / Xcode with a matching macOS SDK
- Python 3 for the lightweight provider hook adapter

## Build

For a complete user-scoped installation:

```sh
./scripts/install.sh
```

This builds and signs the app, installs it at
`~/Applications/Agent Status.app`, configures both Codex and Claude Code hooks,
and launches the app. It does not require `sudo`. Codex still requires you to
open `/hooks` once and trust the newly installed Agent Status hooks.

Useful options:

```sh
./scripts/install.sh --no-hooks
./scripts/install.sh --no-launch
./scripts/install.sh --install-dir /Applications
```

The `/Applications` form may require running the command from an account that
can write there. You can also set `AGENT_STATUS_INSTALL_DIR`.

To remove the user-scoped installation and only Agent Status-owned hook
entries:

```sh
./scripts/uninstall.sh
```

For development:

```sh
swift test
python3 -m unittest discover -s Tests -p '*Tests.py' -v
./scripts/bundle.sh
open "Agent Status.app"
```

The bundle script creates an ad-hoc-signed `Agent Status.app` in the repository
root without installing it. The raw SwiftPM executable can be used for
development, but Launch on Login requires the app bundle.

## Configure providers

Open the menu-bar icon, choose **Settings**, and install the Codex and/or Claude
Code hooks. Existing provider configuration and unrelated hooks are preserved.
The Audio section provides a play button for each selected tone and previews a
tone automatically when its selection changes.

Codex requires newly installed, non-managed hooks to be reviewed and trusted.
Open `/hooks` in Codex after installation and approve the Agent Status entries.

The provider hook sends normalized status events only to an owner-only local
Unix socket. Agent prompts and transcripts are not persisted by Agent Status.
Events from the same provider turn are coalesced even if the provider reports
multiple session identifiers. Exited CLI processes are cleaned up
automatically; inactive Working entries without a dedicated process are
removed after 30 minutes.

## Provider support

| Provider | Integration |
| --- | --- |
| Codex desktop | User-level Codex lifecycle hooks; desktop detection is best-effort |
| Codex CLI | User-level Codex lifecycle hooks |
| Claude Code CLI | Claude Code lifecycle hooks |
| Claude desktop | Experimental: only sessions that invoke compatible local Claude hooks |

Claude desktop does not expose a documented passive conversation-status hook.
Agent Status intentionally avoids brittle Accessibility or screen-scraping
integration.

For Claude Code, `Stop` and generic `idle_prompt` events mean the current turn
is Finished even while the CLI remains open. Explicit permission and
input-required events remain Waiting.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design and operational details.

Inspired by [TeamNoSleepz/notch-agent](https://github.com/TeamNoSleepz/notch-agent);
this implementation has an independent state model and provider integration.
