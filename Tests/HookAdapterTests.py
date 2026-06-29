import importlib.util
import pathlib
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
            "waiting",
        )
        self.assertEqual(HOOK.activity_for("Stop", {}), "finished")
        self.assertEqual(HOOK.activity_for("SessionEnd", {}), "ended")

    def test_stop_question_waits_for_input(self):
        payload = {"last_assistant_message": "Which option should I use?"}
        self.assertEqual(HOOK.activity_for("Stop", payload), "waiting")

    def test_stop_question_with_following_choices_waits_for_input(self):
        payload = {
            "last_assistant_message": "Which option should I use?\n1. Fast\n2. Thorough"
        }
        self.assertEqual(HOOK.activity_for("Stop", payload), "waiting")

    def test_stop_completed_statement_finishes(self):
        payload = {"last_assistant_message": "Implementation and tests are complete."}
        self.assertEqual(HOOK.activity_for("Stop", payload), "finished")

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


if __name__ == "__main__":
    unittest.main()
