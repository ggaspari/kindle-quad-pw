"""Render the Kindle frames from made-up data, no network needed.
python3 kindle_cases.py  ->  kindle_*.png (landscape, as you'd see it) and
kindle_native_quad.png (rotated, exactly what the Kindle gets)."""
import os, time
os.environ.setdefault("TZ", "America/Sao_Paulo"); time.tzset()
import render as R, sources as S, kindle as K

now = time.time()
CFG = {"units": "C", "slots": ["weather", "news", "sports", "sky"], "radar_nm": 25, "sports_logos": False, "odds": True,
       "odds_style": "spread", "news_pages": 4}
lt = time.localtime(now)
day = lambda i: time.strftime("%Y-%m-%d", time.localtime(now + 86400 * i))
wx = S.Weather(temp=29, feels=33, code=2, is_day=lt.tm_hour in range(7, 19), humidity=68, wind=14, wind_dir=120, gust=31,
               days=[S.Day(day(i), hi, lo, code, pop, "05:41", "18:12", uv)
                     for i, (hi, lo, code, pop, uv) in enumerate([(31, 23, 2, 40, 8), (30, 22, 80, 70, 7),
                                                                   (28, 21, 95, 80, 5), (29, 20, 3, 20, 8),
                                                                   (31, 21, 0, 10, 9)])],
               hourly=[(now + 3600 * i, 29 - abs(i - 4) * 0.5, [5, 10, 20, 45, 70, 60, 30, 15, 10, 5, 5, 5][i % 12], 2)
                       for i in range(24)],
               rain_note="Rain likely around 16:00",
               alerts=[("Tempestade", "INMET: Tempestade (Perigo) até 21:00", "Severe")])
heads = [S.Headline(t, "g1", now - 600 * i) for i, t in enumerate([
    "Copom mantém Selic e sinaliza cautela com inflação de serviços",
    "Petrobras anuncia redução no preço do diesel para distribuidoras",
    "Senado aprova projeto que amplia isenção do Imposto de Renda",
    "Frente fria derruba temperaturas no Sul e no Sudeste nesta semana",
    "Dólar fecha em queda e Ibovespa renova máxima do ano",
    "Vendas no varejo sobem acima do esperado em agosto",
    "Governo lança programa de crédito para pequenas empresas",
    "STF retoma julgamento sobre marco temporal",
    "Exportações do agronegócio batem recorde no trimestre",
    "Companhias aéreas ampliam voos para o fim de ano"])]
qs = [S.Quote(sym, name, p, p / (1 + c / 100), [p / (1 + c / 100) * (1 + c / 100 * k / (n - 1)) for k in range(n)], "open", now)
      for sym, name, p, c, n in [("^BVSP", "Ibovespa", 145320.4, 0.85, 50), ("BRL=X", "Dólar", 5.4321, -0.69, 200),
                                 ("IFIX.SA", "IFIX", 3975.77, 0.14, 50), ("BTC-BRL", "Bitcoin", 612345.9, 2.06, 288)]]
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
