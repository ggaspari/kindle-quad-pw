"""Render the Kindle frames from made-up data, no network needed.
python3 kindle_cases.py  ->  kindle_*.png (landscape, as you'd see it) and
kindle_native_quad.png (rotated, exactly what the Kindle gets)."""
import os, time
os.environ.setdefault("TZ", "America/New_York"); time.tzset()
import render as R, sources as S, kindle as K

now = time.time()
CFG = {"slots": ["weather", "news", "sports", "sky"], "radar_nm": 25, "sports_logos": False, "odds": True,
       "odds_style": "spread", "news_pages": 4}
lt = time.localtime(now)
day = lambda i: time.strftime("%Y-%m-%d", time.localtime(now + 86400 * i))
wx = S.Weather(temp=84, feels=91, code=2, is_day=lt.tm_hour in range(7, 19), humidity=68, wind=9, wind_dir=120, gust=19,
               days=[S.Day(day(i), hi, lo, code, pop, "7:24 AM", "7:02 PM", uv)
                     for i, (hi, lo, code, pop, uv) in enumerate([(88, 74, 2, 40, 8), (86, 73, 80, 70, 7),
                                                                   (84, 72, 95, 80, 5), (85, 71, 3, 20, 8),
                                                                   (87, 72, 0, 10, 9)])],
               hourly=[(now + 3600 * i, 84 - abs(i - 4) * 0.8, [5, 10, 20, 45, 70, 60, 30, 15, 10, 5, 5, 5][i % 12], 2)
                       for i in range(24)],
               rain_note="Rain likely around 4 PM")
heads = [S.Headline(t, "world", now - 600 * i) for i, t in enumerate([
    "Fed officials signal patience on further rate cuts as inflation cools unevenly",
    "Oil slides as OPEC+ weighs another output increase",
    "Chip stocks rally after strong outlook from equipment makers",
    "Hurricane season's late surge puts Gulf Coast insurers on alert",
    "Treasury yields climb for a third session",
    "Retail sales beat forecasts, lifting consumer stocks",
    "Europe's carmakers brace for new tariff round",
    "Tech giants race to secure power for AI data centers",
    "Housing starts fall to lowest level in a year",
    "Airlines raise holiday fares as demand stays strong"])]
qs = [S.Quote(sym, name, p, p / (1 + c / 100), [p / (1 + c / 100) * (1 + c / 100 * k / 77) for k in range(78)], "open", now)
      for sym, name, p, c in [("^GSPC", "S&P 500", 6712.4, 0.42), ("^DJI", "Dow", 46210.1, -0.18),
                              ("^IXIC", "Nasdaq", 22950.7, 0.91), ("SOXL", "SOXL", 38.12, 3.4)]]
S.TEAMS.update({"bucs": ("Bucs", "football", "nfl", "tb"), "rays": ("Rays", "baseball", "mlb", "tb"),
                "lightning": ("Lightning", "hockey", "nhl", "tb")})
g = lambda **k: S.Game(**{"team": "", "abbr": "TB", "opp": "NO", "opp_name": "Saints", "home": True,
                          "start": now + 86400, "state": "pre", "detail": "", **k})
teams = [S.TeamRow("bucs", "Bucs", "4-1", last=g(state="post", us=27, them=17, start=now - 86400 * 2, detail="Final"),
                   next=g(opp="DET", opp_name="Lions", home=False, start=now + 86400 * 4, tv="FOX",
                          odds=S.Odds("DraftKings", "TB -3.5", -3.5, 47.5, -180, 150, 62))),
         S.TeamRow("lightning", "Lightning", "2-0-1", live=g(opp="FLA", opp_name="Panthers", state="in", us=2, them=1,
                                                             detail="2nd 12:34", tv="ESPN+")),
         S.TeamRow("rays", "Rays", "79-83", last=g(opp="NYY", opp_name="Yankees", state="post", us=3, them=5,
                                                   start=now - 86400 * 14, detail="Final"))]
fl = R.Sighting(callsign="DAL2474", airline="Delta Air Lines", origin="ATL", dest="TPA", origin_city="Atlanta",
                dest_city="Tampa", alt_ft=6400, speed_kt=252, dist_nm=1.8, elev_deg=31, seen_at=now - 30,
                flight_no="DL 2474", aircraft="Airbus A321neo", bearing=315, progress=0.93, eta_min=9, dest_dist_nm=4)
recent = [R.Sighting(callsign="SWA1", airline="Southwest", origin="BWI", dest="TPA", origin_city="Baltimore",
                     dest_city="Tampa", alt_ft=3000, speed_kt=200, dist_nm=3, elev_deg=12, seen_at=now - 600 * i,
                     flight_no=f"WN {1200 + i}", aircraft="Boeing 737 MAX 8", bearing=10) for i in range(1, 12)]
nearby = [(3, 40, "DAL2474"), (8, 200, "SWA12"), (15, 290, "N123AB"), (21, 100, "JBU55")]
base = dict(now=now, cfg=CFG, weather=wx, heads=heads, quotes=qs, teams=teams, recent=recent, day_count=143,
            nearby=nearby, featured=fl, battery=76, updated=now,
            brief="Yields keep climbing as stocks slip; the Bucs head to Detroit Sunday and rain chances jump Thursday.")
cases = {"quad": R.Ctx(**base)}
for p in ("weather", "news", "sports", "sky"):
    cases[p] = R.Ctx(**base, page=p)
for k, ctx in cases.items():
    K.landscape(ctx).save(f"kindle_{k}.png")
K.frame(cases["quad"]).save("kindle_native_quad.png")
# the E1001 render must be untouched by the Kindle layout swap
assert R.compose(cases["quad"]).size == (R.W, R.H) == (800, 480)
print("ok", list(cases))
