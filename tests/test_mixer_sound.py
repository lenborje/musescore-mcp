import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from musescore_mcp import set_mixer_sound as mixer


class MixerArchiveTests(unittest.TestCase):
    def run_case(self, audio=None, fail_replace=False):
        with tempfile.TemporaryDirectory() as directory:
            score = Path(directory) / "score.mscz"
            xml = '<museScore><Score><Part id="7"><Instrument id="alto"><trackName>Alt</trackName></Instrument></Part><Staff id="1"/></Score></museScore>'
            with zipfile.ZipFile(score, "w") as archive:
                archive.writestr("score.mscx", xml)
                archive.writestr("other.bin", b"keep me")
                if audio is not None:
                    archive.writestr("audiosettings.json", json.dumps(audio))
            original = score.read_bytes()
            parser = mixer.argparse.ArgumentParser()
            mixer.add_arguments(parser)
            args = parser.parse_args([str(score), "--set", "7=altos"])
            with contextlib.redirect_stdout(io.StringIO()):
                if fail_replace:
                    with patch.object(mixer.os, "replace", side_effect=OSError("test failure")):
                        with self.assertRaises(OSError):
                            mixer.run(args)
                    self.assertEqual(score.read_bytes(), original)
                    self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ["score.mscz", "score.mscz.bak"])
                    return
                mixer.run(args)
            self.assertEqual(Path(str(score) + ".bak").read_bytes(), original)
            with zipfile.ZipFile(score) as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(archive.read("score.mscx").decode(), xml)
                self.assertEqual(archive.read("other.bin"), b"keep me")
                self.assertEqual(archive.namelist().count("audiosettings.json"), 1)
                updated = json.loads(archive.read("audiosettings.json"))
            tracks, shape = mixer.tracks_as_list(updated)
            self.assertEqual(shape, "dict" if isinstance((audio or {}).get("tracks"), dict) else "list")
            target = mixer.find_track(tracks, "7")
            self.assertEqual(target["in"]["resourceMeta"]["id"], "50353")
            if audio:
                self.assertEqual(updated["unrelated"], "preserved")
                self.assertEqual(target["out"], {"volumeDb": -6})

    def test_creates_missing_settings(self):
        self.run_case()

    def test_preserves_list_tracks_and_other_settings(self):
        self.run_case({"tracks": [{"partId": "7", "out": {"volumeDb": -6}}], "unrelated": "preserved"})

    def test_preserves_dict_tracks_and_other_settings(self):
        self.run_case({"tracks": {"7": {"out": {"volumeDb": -6}}}, "unrelated": "preserved"})

    def test_failed_replacement_preserves_original(self):
        self.run_case(fail_replace=True)
