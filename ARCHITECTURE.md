# Agent Status Architecture

Agent Status is a menu-bar macOS application that renders a click-expandable
status surface around the built-in display notch. It accepts lifecycle events
from Codex and Claude hooks over a local Unix-domain socket.

## Modules

- `AgentStatusCore`: provider-neutral session model, aggregation, event decoding,
  and the revision-safe three-second Finished lifecycle.
- `AgentStatusApp`: AppKit lifecycle, socket server, hook installation,
  preferences and audio, notch panel geometry, and SwiftUI views.
- `Hooks/agent-status-hook.py`: a fire-and-forget adapter that maps provider
  lifecycle payloads into the normalized socket protocol.

The core module contains no AppKit dependencies so state transitions can be
tested deterministically.

## Normalized event flow

```text
Codex / Claude lifecycle hook
        |
        v
agent-status-hook.py
  - identifies provider and host surface
  - maps lifecycle event to Working / Waiting / Finished / Ended
        |
        v
/tmp/agent-status-<uid>.sock
        |
        v
SessionEventServer
  - owner-only socket permissions
  - bounded JSON payload
  - Codable validation
        |
        v
SessionStore (@MainActor)
  - per-session state and revision
  - Finished expiry
  - priority aggregation
        |
        +--> AudioController (each Waiting/Finished transition)
        |
        +--> NotchPanelController / SwiftUI
```

## Status rules

The displayed status is the highest-priority status currently present:

1. Finished
2. Waiting
3. Working

The displayed count includes only sessions in that status. A Finished session
is removed after three seconds unless a newer event changes its revision.
Transition audio is emitted per session, not per aggregate display change.

## Provider integration

Codex and Claude Code both support command lifecycle hooks whose input is a JSON
object on standard input. The bundled hook adapter accepts the shared event
names and provider-specific fields, then emits a stable normalized event.

Codex CLI and Codex desktop share the user-level `~/.codex/hooks.json`
configuration. Claude Code uses `~/.claude/settings.json`. The hook determines
CLI versus desktop from its process ancestry. Claude desktop support uses the
same adapter when the desktop product invokes compatible local agent hooks;
the app does not infer conversation state from process existence alone.

Hook installers merge only Agent Status entries and preserve unrelated user
configuration. Codex requires the user to review and trust newly installed
non-managed hooks.

## macOS shell

The app is packaged as an `LSUIElement` application. Its notch surface is a
borderless non-activating panel on the built-in display, positioned from
`auxiliaryTopLeftArea`, `auxiliaryTopRightArea`, and `safeAreaInsets`. The
panel joins all Spaces and uses constrained hit testing so transparent areas
do not intercept clicks.

The menu-bar status item opens settings for launch-at-login, separate Waiting
and Finished sound controls, volume, hook installation status, and the source
repository.

## Operational constraints

- The socket is local, owner-only, and recreated after wake or unexpected
  closure.
- Hooks are best-effort and never block the agent workflow on delivery failure.
- Hook payloads and transcript formats are not persisted by the app.
- There are no telemetry or update-service dependencies.
