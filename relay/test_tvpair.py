import unittest

from tvpair import TVPairing


class TVPairTests(unittest.TestCase):
    def test_flow(self):
        tp = TVPairing(lambda: "KEY")
        s, r = tp.start()
        self.assertEqual(s, 200)
        self.assertEqual(tp.poll(r["id"])[1]["status"], "pending")
        self.assertEqual(tp.approve({"code": "000000" if r["code"] != "000000" else "111111", "gateway": "https://g", "relay": "https://r"})[0], 410)
        self.assertEqual(tp.approve({"code": r["code"], "gateway": "https://g:8642/", "relay": "https://r:8651"})[0], 200)
        s, got = tp.poll(r["id"])
        self.assertEqual(got, {"status": "approved", "gateway": "https://g:8642", "relay": "https://r:8651", "api_key": "KEY"})
        self.assertEqual(tp.poll(r["id"])[1]["status"], "expired")   # key released once

    def test_validation_and_limits(self):
        tp = TVPairing(lambda: "KEY")
        _, r = tp.start()
        self.assertEqual(tp.approve({"code": r["code"], "gateway": "javascript:x", "relay": "https://r"})[0], 400)
        self.assertEqual(tp.approve({"code": "12ab", "gateway": "https://g", "relay": "https://r"})[0], 400)
        codes = [tp.start()[0] for _ in range(12)]
        self.assertIn(429, codes)
        self.assertLessEqual(len(tp.pending), 5)


if __name__ == "__main__":
    unittest.main()
