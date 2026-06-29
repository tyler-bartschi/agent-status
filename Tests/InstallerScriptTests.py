import importlib.util
import json
import pathlib
import tempfile
import unittest


SCRIPT_PATH = pathlib.Path(__file__).parents[1] / "scripts" / "configure-hooks.py"
SPEC = importlib.util.spec_from_file_location("configure_hooks", SCRIPT_PATH)
HOOKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOOKS)


class InstallerScriptTests(unittest.TestCase):
    def test_install_is_idempotent_and_preserves_existing_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            source = home / "source-hook.py"
            source.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
            config = home / ".codex" / "hooks.json"
            config.parent.mkdir()
            config.write_text(
                json.dumps(
                    {
                        "unrelated": "keep",
                        "hooks": {
                            "Stop": [
                                {
                                    "hooks": [
                                        {"type": "command", "command": "existing-tool"}
                                    ]
                                }
                            ]
                        },
                    }
                ),
                encoding="utf-8",
            )

            for _ in range(2):
                self.assertEqual(
                    HOOKS.main(
                        [
                            "install",
                            "--provider",
                            "codex",
                            "--hook",
                            str(source),
                            "--home",
                            str(home),
                        ]
                    ),
                    0,
                )

            value = json.loads(config.read_text(encoding="utf-8"))
            self.assertEqual(value["unrelated"], "keep")
            self.assertEqual(len(value["hooks"]["Stop"]), 2)
            for event in HOOKS.CODEX_EVENTS:
                owned = [
                    handler
                    for group in value["hooks"][event]
                    for handler in group.get("hooks", [])
                    if HOOKS.is_owned(handler)
                ]
                self.assertEqual(len(owned), 1)

    def test_uninstall_removes_only_owned_handlers(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            source = home / "source-hook.py"
            source.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
            HOOKS.main(
                [
                    "install",
                    "--provider",
                    "claude",
                    "--hook",
                    str(source),
                    "--home",
                    str(home),
                ]
            )
            config = home / ".claude" / "settings.json"
            value = json.loads(config.read_text(encoding="utf-8"))
            value["theme"] = "dark"
            value["hooks"]["Stop"].append(
                {"hooks": [{"type": "command", "command": "existing-tool"}]}
            )
            config.write_text(json.dumps(value), encoding="utf-8")

            HOOKS.main(
                ["uninstall", "--provider", "claude", "--home", str(home)]
            )

            value = json.loads(config.read_text(encoding="utf-8"))
            self.assertEqual(value["theme"], "dark")
            self.assertEqual(
                value["hooks"]["Stop"],
                [{"hooks": [{"type": "command", "command": "existing-tool"}]}],
            )
            self.assertFalse(
                any(
                    HOOKS.is_owned(handler)
                    for groups in value["hooks"].values()
                    for group in groups
                    for handler in group.get("hooks", [])
                )
            )


if __name__ == "__main__":
    unittest.main()
