import json
import unittest

import model_visibility as mv


class ParseTests(unittest.TestCase):
    def test_parses_stored_keys(self):
        r = mv._parse({
            "visible": json.dumps(["anthropic::claude-opus-5-5", "moa::", 3]),
            "known": json.dumps(["anthropic::claude-opus-5-5"]),
            "favorites": json.dumps(["openai-codex::gpt-6-sol"]),
            "custom": json.dumps([{"provider": "openrouter", "model": "x/y"}, {"bad": 1}]),
        })
        self.assertEqual(r["visible"], ["anthropic::claude-opus-5-5", "moa::"])
        self.assertEqual(r["known"], ["anthropic::claude-opus-5-5"])
        self.assertEqual(r["favorites"], ["openai-codex::gpt-6-sol"])
        self.assertEqual(r["custom"], [{"provider": "openrouter", "model": "x/y"}])

    def test_never_customized_is_null(self):
        r = mv._parse({})
        self.assertIsNone(r["visible"])
        self.assertIsNone(r["known"])
        self.assertEqual(r["favorites"], [])

    def test_missing_app(self):
        from pathlib import Path
        self.assertFalse(mv.read(Path("/nonexistent"))["available"])


if __name__ == "__main__":
    unittest.main()
