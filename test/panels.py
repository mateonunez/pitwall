"""Check that cached records are available before the live reads."""
import base64
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import runpy
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[1]
OT = ROOT / "plugins/opentimeline/bin/opentimeline"
USAGE = ROOT / "bin/pitwall-usage"


class Panels(unittest.TestCase):
    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.preview = self.root / "preview"
        env = patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp.name, "XDG_CACHE_HOME": tmp.name,
                                      "PITWALL_VIEW_PREVIEW": str(self.preview)})
        env.start()
        self.addCleanup(env.stop)

    def test_timeline(self):
        view = runpy.run_path(str(OT))["view"]
        context = view.__globals__
        token = self.root / "seat"
        token.write_text("fixture-token")
        config = Path(context["CONFIG"])
        config.parent.mkdir()
        config.write_text(f"http://127.0.0.1:9\n{token}\n")
        data = {"groups": [{"name": "Project", "stories": [{"conversationId": "s", "title": "Last story"}]}]}

        def render(reply):
            with patch.dict(context, {"options": lambda: {"web": "", "repo": "", "dir": "", "agent": ""},
                                      "token_for": lambda url, path: token.read_text(), "call": reply}):
                with redirect_stdout(io.StringIO()) as output:
                    view()
            return output.getvalue()

        self.assertIn("Last story", render(lambda *args: (200, data)))
        self.assertFalse(self.preview.exists())

        def offline(*args):
            self.assertIn("Last story", self.preview.read_text())
            raise ConnectionError

        self.assertIn("Last seen · refresh failed", render(offline))
        self.assertIn("Last seen · refreshing", self.preview.read_text())

        def denied(*args):
            raise HTTPError("", 403, "Forbidden", {}, None)

        self.assertNotIn("Last story", render(denied))
        self.preview.unlink()
        render(denied)
        self.assertFalse(self.preview.exists())

        render(lambda *args: (200, data))
        token.write_text("other-fixture-token")
        self.assertNotIn("Last story", render(denied))
        self.assertFalse(self.preview.exists())

    def test_usage(self):
        main = runpy.run_path(str(USAGE))["main"]
        source = self.root / "lanes"
        source.write_text("\x1f".join(["1", "working", "lab", "lane", "%1", "0", "codex", "task", "", "test"]) + "\n")

        def sample(server, read):
            with patch("sys.argv", [str(USAGE), str(source), server, str(self.preview)]):
                with patch("subprocess.check_output", side_effect=read), redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(main(), 0)
            return output.getvalue()

        def read_first(command, **kwargs):
            self.assertFalse(self.preview.exists())
            return "before\t1\n" if command[0].name == "pitwall-stats" else "%1\tlane\t20\t10\n"

        self.assertIn("before", sample("123.1", read_first))

        def read_again(command, **kwargs):
            self.assertIn("before", self.preview.read_text())
            return "after\t2\n" if command[0].name == "pitwall-stats" else ""

        self.assertIn("after", sample("123.1", read_again))
        self.preview.unlink()
        self.assertIn("before", sample("123.2", read_first))

    def test_timeline_handoff(self):
        act = runpy.run_path(str(OT))["act"]
        exported = "/v1/events/12345678-1234-1234-1234-123456789012/export"
        data = {"groups": [{"stories": [{"conversationId": "story", "title": "Review",
                                        "changes": [{"eventId": exported.split("/")[3], "summary": "Run the check"}]}]}]}
        calls = []

        def read(url, path, credential):
            self.assertEqual((url, credential), ("http://localhost:4431", "seat"))
            calls.append(path)
            replies = {
                "/v1/today": data,
                exported: {"snapshot": "100", "nextCursor": "30", "markdown": "## First page\nCheckpoint"},
                exported + "?snapshot=100&cursor=30": {"snapshot": "100", "nextCursor": None, "markdown": "## Final page"},
            }
            return 200, replies[path]

        connected = ("http://localhost:4431", "fixture", 1, "seat")
        patches = {"call": read, "connection": lambda: connected, "options": lambda: {"web": ""}}
        with patch.dict(act.__globals__, patches), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(act("handoff", "story"), 0)
        kind, payload = output.getvalue().strip().split("\t")
        self.assertEqual(kind, "handoff")
        note = base64.b64decode(payload).decode()
        self.assertIn("# OpenTimeline · Review", note)
        self.assertIn("http://localhost:4430/events/", note)
        self.assertIn("Run the check", note)
        self.assertIn("## First page\nCheckpoint\n## Final page", note)
        self.assertEqual(calls, ["/v1/today", exported, exported + "?snapshot=100&cursor=30"])

        def deny_export(url, path, credential):
            if path == "/v1/today":
                return read(url, path, credential)
            raise HTTPError("", 403, "Forbidden", {}, None)

        with patch.dict(act.__globals__, {**patches, "call": deny_export}), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(act("handoff", "story"), 0)
        self.assertEqual(output.getvalue(), "notice\tOpenTimeline could not read this story\n")
        with patch.dict(act.__globals__, patches), patch.dict(act.__globals__, {
            "connection": unittest.mock.Mock(side_effect=[connected, (*connected[:3], "other-seat")]),
        }), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(act("handoff", "story"), 0)
        self.assertEqual(output.getvalue(), "notice\tOpenTimeline could not read this story\n")

    def test_timeline_space_context(self):
        run = runpy.run_path(str(OT))["cmd"]
        allowed = "12345678-1234-1234-1234-123456789012"
        outside = "12345678-1234-1234-1234-123456789013"
        records = {allowed: {"id": allowed, "space": {"id": "local"}, "presentation": {"title": "Local story"}},
                   outside: {"id": outside, "space": {"id": "outside"}, "presentation": {"title": "Outside story"}}}
        calls = []

        def read(url, path, token):
            calls.append(path)
            if path == "/v1/spaces/mate":
                return 200, {"id": "local", "slug": "mate"}
            if path == "/v1/events?space=mate&limit=30&q=local+story":
                return 200, {"items": list(records.values())}
            if path == f"/v1/events/{allowed}/export":
                return 200, {"markdown": "Local evidence\n", "nextCursor": None}
            return 200, records[path.split("/")[-1]]

        patches = {"connection": lambda: ("http://localhost:4431", "fixture", 1, "seat"),
                   "call": read, "options": lambda: {"web": ""}}
        with patch.dict(run.__globals__, patches), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(run(["stories", "--space", "mate", "local story"]), 0)
            self.assertIn("Local story", output.getvalue())
            self.assertNotIn("Outside story", output.getvalue())
        with patch.dict(run.__globals__, patches), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(run(["context", "--space", "mate", allowed]), 0)
            self.assertIn("Local evidence", output.getvalue())
        with patch.dict(run.__globals__, patches), redirect_stdout(io.StringIO()) as output, patch("sys.stderr", io.StringIO()):
            self.assertEqual(run(["context", "--space", "mate", outside]), 1)
            self.assertEqual(output.getvalue(), "")
        self.assertNotIn(f"/v1/events/{outside}/export", calls)

    def test_superseded_refresh(self):
        snapshot = runpy.run_path(str(USAGE))["Snapshot"]
        older = snapshot("view", ["seat"])
        newer = snapshot("view", ["seat"])
        newer.save(None)
        older.save("data from before disconnect")
        self.assertIsNone(snapshot("view", ["seat"]).read())


if __name__ == "__main__":
    unittest.main()
