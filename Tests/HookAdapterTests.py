import importlib.util
import io
import json
import pathlib
import sys
import unittest
from unittest import mock


HOOK_PATH = (
    pathlib.Path(__file__).parents[1]
    / "Sources"
    / "AgentStatusApp"
    / "Hooks"
    / "agent-status-hook.py"
)
SPEC = importlib.util.spec_from_file_location("agent_status_hook", HOOK_PATH)
HOOK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOOK)


class HookAdapterTests(unittest.TestCase):
    def test_maps_lifecycle_states(self):
        self.assertEqual(HOOK.activity_for("UserPromptSubmit", {}), "working")
        self.assertEqual(HOOK.activity_for("PreToolUse", {}), "working")
        self.assertEqual(HOOK.activity_for("PermissionRequest", {}), "waiting")
        self.assertEqual(
            HOOK.activity_for("Notification", {"notification_type": "idle_prompt"}),
            "working",
        )
        self.assertEqual(HOOK.activity_for("Stop", {}), "finished")
        self.assertEqual(HOOK.activity_for("SessionEnd", {}), "ended")

    def test_stop_question_waits_for_input(self):
        payload = {"last_assistant_message": "Which option should I use?"}
        self.assertEqual(HOOK.activity_for("Stop", payload, "codex"), "waiting")

    def test_stop_question_with_following_choices_waits_for_input(self):
        payload = {
            "last_assistant_message": "Which option should I use?\n1. Fast\n2. Thorough"
        }
        self.assertEqual(HOOK.activity_for("Stop", payload, "codex"), "waiting")

    def test_stop_completed_statement_finishes(self):
        payload = {"last_assistant_message": "Implementation and tests are complete."}
        self.assertEqual(HOOK.activity_for("Stop", payload, "codex"), "finished")

    def test_claude_stop_is_finished_even_when_text_contains_a_question(self):
        payload = {"last_assistant_message": "Anything else?"}
        self.assertEqual(HOOK.activity_for("Stop", payload, "claude"), "finished")

    def test_claude_idle_notification_is_finished_not_waiting(self):
        payload = {"notification_type": "idle_prompt"}
        self.assertEqual(
            HOOK.activity_for("Notification", payload, "claude"),
            "finished",
        )

    def test_claude_permission_notification_remains_waiting(self):
        payload = {"notification_type": "permission_prompt"}
        self.assertEqual(
            HOOK.activity_for("Notification", payload, "claude"),
            "waiting",
        )

    def test_terminal_app_does_not_make_cli_a_desktop_session(self):
        with mock.patch.object(
            HOOK,
            "process_ancestry",
            return_value=["/applications/utilities/terminal.app/contents/macos/terminal"],
        ):
            self.assertEqual(HOOK.host_for("codex", {}), "codexCLI")
            self.assertEqual(HOOK.host_for("claude", {}), "claudeCLI")

    def test_provider_desktop_ancestry_is_detected(self):
        with mock.patch.object(
            HOOK,
            "process_ancestry",
            return_value=["/applications/codex.app/contents/macos/codex"],
        ):
            self.assertEqual(HOOK.host_for("codex", {}), "codexDesktop")

    def test_normalized_event_retains_turn_process_and_hook_metadata(self):
        payload = {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-1",
            "turn_id": "turn-1",
            "cwd": "/tmp/project",
        }
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))):
            with mock.patch.object(
                sys,
                "argv",
                ["agent-status-hook.py", "--provider", "codex"],
            ):
                with mock.patch.object(
                    HOOK,
                    "provider_process_id",
                    return_value=123,
                ):
                    with mock.patch.object(HOOK, "send_event") as send_event:
                        HOOK.main()

        normalized = send_event.call_args.args[0]
        self.assertEqual(normalized["turnID"], "turn-1")
        self.assertEqual(normalized["workingDirectory"], "/tmp/project")
        self.assertEqual(normalized["processID"], 123)
        self.assertEqual(normalized["sourceEvent"], "UserPromptSubmit")

    def test_provider_pid_skips_hook_shell_and_finds_node_based_claude(self):
        with mock.patch.object(
            HOOK,
            "process_chain",
            return_value=[
                (100, "/bin/sh agent-status-hook.py --provider claude"),
                (90, "/usr/local/bin/node /opt/claude-code/cli.js"),
            ],
        ):
            self.assertEqual(HOOK.provider_process_id("claude"), 90)

    def test_compaction_events_do_not_restart_activity(self):
        self.assertIsNone(
            HOOK.activity_for("PreCompact", {"trigger": "auto"}, "claude")
        )
        self.assertIsNone(
            HOOK.activity_for(
                "PostCompact",
                {"trigger": "auto", "compact_summary": "recap"},
                "claude",
            )
        )
        self.assertIsNone(
            HOOK.activity_for("SessionStart", {"source": "compact"}, "claude")
        )

    def test_regular_session_start_remains_idle(self):
        self.assertEqual(
            HOOK.activity_for("SessionStart", {"source": "startup"}, "claude"),
            "idle",
        )


if __name__ == "__main__":
    unittest.main()
