"""Installation and diagnostics in isolated directories; no real plugin is changed."""

import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from musescore_mcp import __version__, cli, installation


class IsolatedInstallation:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.enterContext(patch.dict(os.environ, {}, clear=True))
        self.enterContext(patch.object(Path, "home", return_value=self.home))

    def run_cli(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            cli.main(list(args))
        return output.getvalue()

    def xdg_config(self, content, config=None):
        config = config or self.home / ".config"
        config.mkdir(parents=True, exist_ok=True)
        (config / "user-dirs.dirs").write_text(content, encoding="utf-8")


class InstallationTests(IsolatedInstallation, unittest.TestCase):
    def test_default_location_on_mac_and_linux(self):
        for platform in ("darwin", "linux"):
            with self.subTest(platform=platform), patch.object(installation.sys, "platform", platform):
                self.assertEqual(installation.plugin_dirs()[0],
                                 self.home / "Documents/MuseScore4/Plugins")

    def test_linux_localized_documents_and_custom_config_home(self):
        config = self.home / "config with spaces"
        self.xdg_config('XDG_DOCUMENTS_DIR="$HOME/Mina dokument åäö"\n', config)
        with patch.object(installation.sys, "platform", "linux"), patch.dict(
                os.environ, {"XDG_CONFIG_HOME": str(config)}):
            self.assertEqual(installation.plugin_dirs()[0],
                             self.home / "Mina dokument åäö/MuseScore4/Plugins")

    def test_linux_absolute_documents_with_comment(self):
        documents = self.home / "Other documents"
        self.xdg_config(f'XDG_DOCUMENTS_DIR="{documents.as_posix()}" # comment\n')
        with patch.object(installation.sys, "platform", "linux"):
            self.assertEqual(installation.documents_dir(), documents)

    def test_linux_disabled_documents_uses_home(self):
        self.xdg_config('XDG_DOCUMENTS_DIR="${HOME}/"\n')
        with patch.object(installation.sys, "platform", "linux"):
            self.assertEqual(installation.documents_dir(), self.home)

    def test_linux_invalid_config_falls_back(self):
        for content in ('XDG_DOCUMENTS_DIR="relative"', 'XDG_DOCUMENTS_DIR="unterminated'):
            self.xdg_config(content)
            with self.subTest(content=content), patch.object(installation.sys, "platform", "linux"):
                self.assertEqual(installation.documents_dir(), self.home / "Documents")

    def test_windows_redirected_documents_and_fallback(self):
        redirected = self.home / "OneDrive/Dokument"
        with patch.object(installation.sys, "platform", "win32"):
            with patch.object(installation, "_windows_documents_dir", return_value=redirected):
                self.assertEqual(installation.plugin_dirs(), [redirected / "MuseScore4/Plugins"])
            with patch.object(installation, "_windows_documents_dir", return_value=None):
                self.assertEqual(installation.documents_dir(), self.home / "Documents")

    def test_windows_known_folder_api_and_memory_cleanup(self):
        import ctypes
        from uuid import UUID

        name = str(self.home / "OneDrive/Dokument åäö")
        buffer = ctypes.create_unicode_buffer(name)

        def get_path(folder, flags, token, output):
            self.assertEqual(ctypes.string_at(folder, 16),
                             UUID("fdd39ad0-238f-46af-adb4-6c85480369c7").bytes_le)
            ctypes.cast(output, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.addressof(buffer)
            return 0

        shell = Mock()
        shell.SHGetKnownFolderPath = Mock(side_effect=get_path)
        ole = Mock()
        with patch.object(ctypes, "WinDLL", side_effect=[shell, ole], create=True):
            self.assertEqual(installation._windows_documents_dir(), Path(name))
        self.assertEqual(ole.CoTaskMemFree.call_count, 1)
        self.assertEqual(ole.CoTaskMemFree.call_args.args[0].value, ctypes.addressof(buffer))

    def test_windows_api_unavailable_falls_back(self):
        import ctypes

        with patch.object(ctypes, "WinDLL", side_effect=OSError("unavailable"), create=True):
            self.assertIsNone(installation._windows_documents_dir())

    def test_explicit_directory_wins_over_environment_and_default(self):
        custom = self.home / "Custom plugins"
        with patch.dict(os.environ, {"MUSESCORE_MCP_PLUGIN_DIR": str(self.home / "env")}), \
                patch.object(installation, "documents_dir", side_effect=AssertionError("must not probe")):
            self.assertEqual(installation.plugin_dirs(str(custom)), [custom])
            self.assertEqual(installation.plugin_dirs(), [self.home / "env"])

    def test_empty_directory_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "must not be empty"):
            installation.plugin_dirs(" ")

    def test_unwritable_destination_returns_actionable_cli_error(self):
        target = self.home / "a file"
        target.write_text("keep", encoding="utf-8")
        error = io.StringIO()
        with contextlib.redirect_stderr(error), self.assertRaises(SystemExit) as result:
            self.run_cli("install-plugin", "--plugin-dir", str(target))
        self.assertEqual(result.exception.code, 1)
        self.assertIn("error:", error.getvalue())
        self.assertEqual(target.read_text(encoding="utf-8"), "keep")

    def test_dry_run_never_creates_directory(self):
        target = self.home / "not yet created"
        output = self.run_cli("install-plugin", "--plugin-dir", str(target), "--dry-run", "--allow-eval")
        self.assertFalse(target.exists())
        self.assertIn(str(target / cli.PLUGIN_FILENAME), output)
        self.assertIn("allowEval: true", output)

    def test_install_backup_and_explicit_eval_on_reinstall(self):
        target = self.home / "Custom plugins åäö"
        output = self.run_cli("install-plugin", "--plugin-dir", str(target), "--allow-eval")
        dest = target / cli.PLUGIN_FILENAME
        first = dest.read_bytes()
        self.assertIn(b"property bool allowEval: true", first)
        self.assertIn(str(dest), output)
        self.run_cli("install-plugin", "--plugin-dir", str(target))
        self.assertEqual(dest.with_name(dest.name + ".bak").read_bytes(), first)
        self.assertIn("property bool allowEval: false", dest.read_text(encoding="utf-8"))

    def test_linux_install_ignores_existing_empty_legacy_folder(self):
        legacy = self.home / ".local/share/MuseScore/MuseScore4/Plugins"
        legacy.mkdir(parents=True)
        with patch.object(installation.sys, "platform", "linux"):
            self.run_cli("install-plugin")
        self.assertTrue((self.home / "Documents/MuseScore4/Plugins" / cli.PLUGIN_FILENAME).is_file())
        self.assertEqual(list(legacy.iterdir()), [])

    def test_install_uses_environment_override(self):
        custom = self.home / "env plugins"
        with patch.dict(os.environ, {"MUSESCORE_MCP_PLUGIN_DIR": str(custom)}):
            self.run_cli("install-plugin")
        self.assertTrue((custom / cli.PLUGIN_FILENAME).is_file())


class DoctorTests(IsolatedInstallation, unittest.TestCase):
    # Keep the doctor probe completely isolated from a real MuseScore session.
    def doctor(self, *args, reply=None, raw_reply=None):
        class Probe:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *exc):
                pass

            async def send(self, message):
                assert json.loads(message)["action"] == "ping"

            async def recv(self):
                if raw_reply is not None:
                    return raw_reply
                return json.dumps(reply if reply is not None else
                                  {"status": "success", "result": "pong", "pluginVersion": __version__})

        with patch.object(cli.websockets, "connect", return_value=Probe()) as connect:
            output = io.StringIO()
            with contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as result:
                cli.main(["doctor", *args])
        return output.getvalue(), result.exception.code, connect

    def test_doctor_uses_custom_directory_and_endpoint(self):
        custom = self.home / "Custom plugins"
        self.run_cli("install-plugin", "--plugin-dir", str(custom))
        with patch.dict(os.environ, {"MUSESCORE_MCP_HOST": "127.0.0.1", "MUSESCORE_MCP_PORT": "9000"}):
            output, code, connect = self.doctor("--plugin-dir", str(custom))
        self.assertEqual(code, 0)
        self.assertIn(f"[ok] plugin {custom}", output)
        self.assertNotIn("plugin not installed", output)
        self.assertEqual(connect.call_args.args[0], "ws://127.0.0.1:9000")

    def test_doctor_reports_legacy_copy(self):
        legacy = self.home / ".config/MuseScore/MuseScore4/plugins"
        self.run_cli("install-plugin", "--plugin-dir", str(legacy))
        with patch.object(installation.sys, "platform", "linux"):
            output, code, _ = self.doctor()
        self.assertEqual(code, 0)
        self.assertIn("legacy plugin location", output)

    def test_doctor_rejects_unexpected_ping(self):
        output, code, _ = self.doctor(reply={"status": "error", "message": "wrong service"})
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] unexpected ping", output)

    def test_doctor_rejects_invalid_json_ping(self):
        output, code, _ = self.doctor(raw_reply="not JSON")
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] invalid JSON ping", output)

    def test_doctor_warns_on_live_version_mismatch(self):
        output, code, _ = self.doctor(reply={"status": "success", "result": "pong", "pluginVersion": "0.0"})
        self.assertEqual(code, 0)
        self.assertIn("[warn] live plugin", output)
        self.assertIn("MISMATCH", output)
