import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


class ConfigureAITest(unittest.TestCase):
    def test_updates_only_selected_provider_without_printing_key(self):
        script = Path(__file__).resolve().parents[1] / "bin/configure-ai"
        with tempfile.TemporaryDirectory() as home:
            path = Path(home) / "settings.json"
            path.write_text(json.dumps({"custom_setting": 7, "modsmith_model": "old"}))
            output = io.StringIO()
            with patch.dict(os.environ, {"BOWSER_HOME": home}), \
                 patch("builtins.input", side_effect=["anthropic", ""]), \
                 patch("getpass.getpass", return_value="test-only-credential"), \
                 contextlib.redirect_stdout(output):
                runpy.run_path(str(script), run_name="__main__")
            settings = json.loads(path.read_text())
            self.assertEqual(settings["ai_provider"], "anthropic")
            self.assertEqual(settings["anthropic_api_key"], "test-only-credential")
            self.assertEqual(settings["custom_setting"], 7)
            self.assertNotIn("modsmith_model", settings)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("test-only-credential", output.getvalue())

    def test_empty_key_does_not_touch_existing_settings(self):
        script = Path(__file__).resolve().parents[1] / "bin/configure-ai"
        with tempfile.TemporaryDirectory() as home:
            path = Path(home) / "settings.json"
            path.write_text('{"custom_setting":7}')
            original = path.read_bytes()
            with patch.dict(os.environ, {"BOWSER_HOME": home}), \
                 patch("builtins.input", return_value="openai"), \
                 patch("getpass.getpass", return_value=""), self.assertRaises(SystemExit):
                runpy.run_path(str(script), run_name="__main__")
            self.assertEqual(path.read_bytes(), original)
