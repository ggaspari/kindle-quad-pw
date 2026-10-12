# Quad Board — Kindle Paperwhite edition

> Based on [j-rod-ay/eink-quad](https://github.com/j-rod-ay/eink-quad) (MIT). This copy adds a jailbroken
> first-gen **Kindle Paperwhite** as a screen: see [`kindle/README.md`](kindle/README.md) (pt-BR).

An e-paper kitchen dashboard for the Seeed reTerminal E1001. Four corners of your day on a 7.5" screen: the weather, the news and markets, your teams, and whatever is flying over the house right now.

![Quad Board cycling through its pages](docs/img/demo.gif)

**[See the project page →](https://j-rod-ay.github.io/eink-quad/)**

🖥️ **The screen: [Seeed reTerminal E1001 on Amazon](https://link.amazon/B0gH6ekeP)** — 7.5″ 800×480 mono e-paper, ESP32-S3, battery. *(affiliate link)*

## What's on it

| Corner | Shows |
|---|---|
| **Weather** | current conditions, rain chance for the next few hours, 3-day forecast, 15-minute rain nowcast, official alerts (INMET in Brazil, NWS in the US) |
| **News & markets** | index and ticker moves, rotating headlines (g1, Agência Brasil, Folha, BBC News Brasil; WSJ still available) |
| **Your teams** | live score, last result or next game for any ESPN team, with TV and the betting line |
| **Sea (default here)** | next high/low tide, the tide curve, waves and water temperature, from Open-Meteo Marine; `sky_mode` = `planes` brings the plane corner back |
| **Plane overhead** | airline, route, aircraft, altitude and which way to look, from live ADS-B. An ISS pass or a visible rocket launch takes this corner over |

A strip under the header carries one line: your own pinned message, a severe weather alert, or a sentence from Claude that ties the day together (optional).

The three buttons on top work as **home**, **previous page** and **next page**. Each corner has its own detail page:

| | |
|---|---|
| ![Weather](docs/img/weather.png) | ![News & markets](docs/img/news.png) |
| ![Scores](docs/img/sports.png) | ![Sky above](docs/img/sky.png) |

## How it works

The screen doesn't decide anything. A small Python server renders every pixel with Pillow, diffs the frame against what's already on the glass, and hands the board only the rectangles that changed. The board long-polls over HTTPS (or deep-sleeps between checks on battery) and plays those rectangles as ~1 s partial refreshes. A full refresh with 4 grey levels runs on the regular update, and a flashing one every couple of hours wipes ghosting.

Changing the layout, the cadence or a data source never means reflashing. Everything is a setting on the server's web dashboard.

```
server/    Python: data sources, renderer, long-poll server, settings dashboard
firmware/  PlatformIO / Arduino for the reTerminal E1001 (ESP32-S3)
kindle/    KUAL extension + busybox client for a jailbroken Kindle Paperwhite
docs/      the project page and screenshots
```

## Also on a Kindle

A jailbroken first-gen **Kindle Paperwhite** works as a second screen: the server renders a 16-grey landscape version and a busybox script on the Kindle shows it, with tap zones for previous / home / next. See [`kindle/README.md`](kindle/README.md).

![Quad Board on a Kindle Paperwhite](docs/img/kindle-quad.png)

## Data sources

All keyless: Open-Meteo (forecast + nowcast, worldwide), INMET (alerts, Brazil) or api.weather.gov (alerts, US), RSS from g1 / Agência Brasil / Folha / BBC News Brasil (or WSJ), Yahoo Finance spark, ESPN's site API, adsb.lol + adsbdb, CelesTrak + Launch Library 2. The one-line brief uses the [`claude`](https://docs.claude.com/en/docs/claude-code) CLI if it's installed and logged in. Turn `llm_brief` off otherwise.

## Setup

### Hardware
- **[Seeed reTerminal E1001](https://link.amazon/B0gH6ekeP)** — 7.5" 800×480 mono e-paper, ESP32-S3 *(affiliate link; also at [Seeed](https://www.seeedstudio.com/))*
- An always-on machine for the server (VPS, Raspberry Pi, NAS), reachable from the board over **HTTPS**. Put it behind nginx or Caddy. The firmware doesn't verify certificates, so a self-signed one works too.

### Server

**On CasaOS / Docker:** `docker compose up -d --build` from the repo root (set `QUAD_TOKEN` and `QUAD_ADMIN` in `.env` first). Step by step, in Portuguese: [`CASAOS.md`](CASAOS.md).

Or straight from Python:

```sh
cd server
pip install -r requirements.txt
cp quad.env.example quad.env       # set QUAD_TOKEN and QUAD_ADMIN
set -a; . ./quad.env; set +a
python app.py                      # listens on 127.0.0.1:8740
```

Open `http://127.0.0.1:8740/?k=<QUAD_ADMIN>` to set your location, units, feeds, tickers, teams, panel order and refresh cadence. Settings are saved to `config.json`.

**Preview without hardware:** `python cases.py` renders every screen with live data to `case_*.png`.

**Your teams:** this edition defaults to the Brasileirão: `bahia`, `sao_paulo` and `g4`, which pulls in whoever is in the top four of ESPN's live `bra.1` table (set `g4_size` to change how many). Soccer teams show their table position and points, and their Libertadores, Sul-Americana and Copa do Brasil games too. The original Tampa keys (`bucs`, `lightning`, `rays`, `gators_fb`, `gators_bb`) are still there. Add your own in `config.json` with ESPN's sport, league and team id or abbreviation, e.g. `"flamengo": ["Flamengo", "soccer", "bra.1", "819"]` (the id is in the club's espn.com.br URL):

```json
{
  "city": "Chicago",
  "lat": 41.8781, "lon": -87.6298,
  "custom_teams": {
    "bears": ["Bears", "football", "nfl", "chi"],
    "cubs":  ["Cubs", "baseball", "mlb", "chc"]
  },
  "teams": ["bears", "cubs"]
}
```

### Firmware

```sh
cd firmware
cp src/secrets.example.h src/secrets.h   # your server's host and QUAD_TOKEN
pio run -t upload --upload-port COM9     # or upload.bat COM9 on Windows
```

On first boot the board opens a Wi-Fi setup portal named `QuadBoard-XXXX`. Join it from your phone and pick your network. To get back to it later, hold the right button and tap the left one.

`firmware/serial.ps1 -Port COM9` resets the board and prints its boot log.

## Notes

- The sky corner defaults to the sea (`sky_mode: sea`): community ADS-B networks (adsb.lol, adsb.fi, OpenSky) have no receivers around Salvador. Tides come from an ocean model: good for "when is the water high", not for navigation.
- The default location is Salvador, BA (-12.9711, -38.5108; IBGE 2927408 for INMET alerts). Change city, latitude and longitude on the dashboard.
- Times use the server's `TZ` (defaults to `America/Sao_Paulo`). Market hours are always NYSE's.
- Units default to °C and km/h, the clock to 24-hour, the board's language to Portuguese (dates, labels, weather, sports and sky; `lang` = `en` switches it all back) and numbers to 1.234,56; all switch on the dashboard.
- Default tickers: Ibovespa (`^BVSP`), dólar (`BRL=X`), IFIX (`IFIX.SA`) and bitcoin in reais (`BTC-BRL`). Each one's open/closed state follows its own market (B3, FX, crypto or NYSE).
- The notes feature reads a separate "note box" project's database and is off unless `QUAD_NOTES_DB` is set.
- Team logos and airline logos are downloaded at runtime and cached in `server/cache/`. None are shipped in this repo.

## License

MIT. Bundled fonts carry their own licences, listed in [`server/fonts/LICENSES.md`](server/fonts/LICENSES.md).
