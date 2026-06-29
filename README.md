# Agent Status

A personal macOS menu-bar app that shows the state of local Codex and Claude
Code sessions around the MacBook notch.

- Yellow: Working
- Red: Waiting for input or permission
- Green: Finished (shown for three seconds)

The right-side number counts sessions in the currently displayed state. Click
the notch surface to expand a list of all active sessions.

## Requirements

- macOS 13 or newer
- Swift 6 / Xcode with a matching macOS SDK
- Python 3 for the lightweight provider hook adapter

## Build

```sh
swift test
python3 -m unittest discover -s Tests -p '*Tests.py' -v
./scripts/bundle.sh
open "Agent Status.app"
```

The bundle script creates an ad-hoc-signed `Agent Status.app` in the repository
root. The raw SwiftPM executable can be used for development, but Launch on
Login requires the app bundle.

## Configure providers

Open the menu-bar icon, choose **Settings**, and install the Codex and/or Claude
Code hooks. Existing provider configuration and unrelated hooks are preserved.

Codex requires newly installed, non-managed hooks to be reviewed and trusted.
Open `/hooks` in Codex after installation and approve the Agent Status entries.

The provider hook sends normalized status events only to an owner-only local
Unix socket. Agent prompts and transcripts are not persisted by Agent Status.

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

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design and operational details.

Inspired by [TeamNoSleepz/notch-agent](https://github.com/TeamNoSleepz/notch-agent);
this implementation has an independent state model and provider integration.
