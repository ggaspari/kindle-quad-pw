"""The local station feed: python -m unittest discover -s server/tests"""
import http.server
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import adsb  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SALVADOR = (-12.9711, -38.5108)


class _Station(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=HERE, **kw)

    def log_message(self, *a):
        pass


class LocalFeed(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Station)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.srv.server_port}/station_aircraft.json"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        adsb.LOCAL_URL, adsb.USE_PUBLIC = self.url, False
        adsb.FEED_STATUS.clear()

    def tearDown(self):
        adsb.LOCAL_URL, adsb.USE_PUBLIC = "", True

    def test_filters_radius_stale_and_positionless(self):
        acs = adsb.fetch_nearby(*SALVADOR, radius_nm=40)
        self.assertEqual(sorted(a["hex"] for a in acs), ["e47f10", "e48a3c", "e4904b"])
        self.assertEqual(adsb.FEED_STATUS, {"station": 3})
        self.assertTrue(all(a["_src"] == "station" for a in acs))

    def test_ranking_uses_station_data(self):
        acs = adsb.fetch_nearby(*SALVADOR, radius_nm=40)
        top = adsb.rank(acs, mode="overhead")
        self.assertEqual(top[0].callsign, "GLO1690")
        self.assertNotIn("TAM3320", [a.callsign for a in top])   # on the ground

    def test_station_down_raises_when_alone(self):
        adsb.LOCAL_URL = self.url.replace("station_aircraft", "missing")
        with self.assertRaises(RuntimeError):
            adsb.fetch_nearby(*SALVADOR, radius_nm=40)
        self.assertTrue(adsb.FEED_STATUS["station"].startswith("error"))

    def test_public_feeds_join_when_enabled(self):
        adsb.USE_PUBLIC = True
        names = [f[0] for f in adsb._feeds(*SALVADOR, 40)]
        self.assertEqual(names, ["station", "adsb.lol", "adsb.fi"])
        adsb.LOCAL_URL = ""
        adsb.USE_PUBLIC = False     # without a station, the networks are the only source
        self.assertEqual([f[0] for f in adsb._feeds(*SALVADOR, 40)], ["adsb.lol", "adsb.fi"])


if __name__ == "__main__":
    unittest.main()
