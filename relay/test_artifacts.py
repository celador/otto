import json
import os
import tempfile
import unittest

import artifacts as A


class ExtractTests(unittest.TestCase):
    def session(self):
        return {"id": "s1", "title": "Test chat", "profile": "default", "last_active": 1790000000}

    def run_msgs(self, msgs):
        return {a["value"]: a for a in A.collect_for_session(self.session(), msgs)}

    def test_media_tag_and_links(self):
        got = self.run_msgs([{"role": "assistant", "timestamp": "1790000001",
            "content": "Here.\n\nMEDIA:/Users/sam/x/Report DRAFT.pdf\nSee https://example.com/a and ![p](/tmp/a.png) [doc](https://x.io/f.csv)"}])
        self.assertEqual(got["/Users/sam/x/Report DRAFT.pdf"]["kind"], "file")
        self.assertEqual(got["/tmp/a.png"]["kind"], "image")
        self.assertEqual(got["https://example.com/a"]["kind"], "link")
        self.assertIn("https://x.io/f.csv", got)
        self.assertEqual(got["/Users/sam/x/Report DRAFT.pdf"]["label"], "Report DRAFT.pdf")

    def test_user_messages_ignored_and_pip_filtered(self):
        got = self.run_msgs([
            {"role": "user", "content": "MEDIA:/tmp/secret.png"},
            {"role": "tool", "tool_name": "terminal", "content": json.dumps({"output": "Downloading https://files.pythonhosted.org/packages/aa/x-1.0-py3-none-any.whl\nwrote /tmp/out.png"})},
        ])
        self.assertNotIn("/tmp/secret.png", got)
        self.assertIn("/tmp/out.png", got)
        self.assertFalse(any(".whl" in k for k in got))

    def test_producer_tool_keys(self):
        got = self.run_msgs([{"role": "tool", "tool_name": "image_generate", "content": json.dumps({"image_path": "/tmp/gen.webp", "note": "/tmp/ignored.png"})},
                             {"role": "tool", "tool_name": "read_file", "content": json.dumps({"path": "/tmp/read.md"})}])
        self.assertIn("/tmp/gen.webp", got)
        self.assertNotIn("/tmp/read.md", got)   # read_file isn't a producer

    def test_file_served_only_if_indexed(self):
        d = tempfile.mkdtemp()
        f = os.path.join(d, "a.txt"); open(f, "w").write("hi")
        sessions = {"sessions": [{"id": "s1", "title": "T", "profile": "default", "message_count": 1, "last_active": 1}]}
        page = {"messages": [{"role": "assistant", "content": f"MEDIA:{f}"}], "pagination": {"limit": 100}}
        dash = lambda m, p, q=None, b=None: sessions if p == "/api/profiles/sessions" else page
        idx = A.ArtifactIndex(dash)
        res = idx.build()
        self.assertEqual(res["artifacts"][0]["exists"], True)
        data, mime, _ = idx.file(f)
        self.assertEqual(data, b"hi")
        with self.assertRaises(PermissionError):
            idx.file("/etc/hosts")


if __name__ == "__main__":
    unittest.main()
