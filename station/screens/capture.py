"""README screenshots of adsb-config: python3 station/screens/capture.py

Runs the real menu in an 80x24 pseudo-terminal with sample data
(station/screens/demo.sh), reads the screen with pyte and draws it with
Pillow into docs/img/station/. Needs: whiptail, jq, qrencode, pyte, Pillow;
run as root (adsb-config insists), it writes only to a temporary directory.
The station's web page (web.png) also needs node with playwright."""
import functools
import http.server
import os
import pty
import select
import shutil
import subprocess
import tempfile
import threading
import time

import pyte
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(REPO, "docs", "img", "station")
CONFIG = os.path.join(REPO, "station", "rootfs", "usr", "local", "sbin", "adsb-config")
FONT = os.path.join(REPO, "server", "fonts", "DejaVuSansMono-Bold.ttf")
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
COLS, ROWS = 80, 24

DOWN, ENTER, TAB = b"\x1b[B", b"\r", b"\t"
SCREENS = [  # name, keys from the main menu[, extra environment]
    ("menu", []),
    ("status", [ENTER]),
    ("location", [DOWN, ENTER]),
    ("wifi", [DOWN, DOWN, ENTER]),
    ("wifi-scan", [DOWN, DOWN, ENTER, ENTER]),
    ("wifi-password", [DOWN, DOWN, ENTER, ENTER, ENTER, b"minhasenha"]),
    ("radio", [DOWN, DOWN, DOWN, ENTER]),
    ("map", [DOWN] * 5 + [ENTER], {"DEMO_MAP": "no"}),   # offers to install it
    ("map-installed", [DOWN] * 5 + [ENTER]),             # update / remove
    ("qr", [ENTER, TAB, ENTER]),          # Estado > "QR / copiar URL"
]

# the Linux console palette whiptail (newt) is drawn with
PALETTE = {
    "black": (0, 0, 0), "red": (170, 0, 0), "green": (0, 170, 0), "brown": (170, 85, 0),
    "blue": (0, 0, 170), "magenta": (170, 0, 170), "cyan": (0, 170, 170), "white": (170, 170, 170),
}
BRIGHT = {
    "black": (85, 85, 85), "red": (255, 85, 85), "green": (85, 255, 85), "brown": (255, 255, 85),
    "blue": (85, 85, 255), "magenta": (255, 85, 255), "cyan": (85, 255, 255), "white": (255, 255, 255),
}


def color(name, bold, default):
    if name == "default":
        return default
    if len(name) == 6 and all(c in "0123456789abcdef" for c in name):
        return tuple(int(name[i:i + 2], 16) for i in (0, 2, 4))
    return (BRIGHT if bold else PALETTE).get(name, default)


def grab(keys, state, run, extra=None):
    # NEWT_COLORS: Debian's blue background (Ubuntu repaints whiptail purple)
    env = dict(os.environ, TERM="xterm", LANG="C.UTF-8", LC_ALL="C.UTF-8", NEWT_COLORS="root=white,blue",
               ADSB_LIB=os.path.join(HERE, "demo.sh"), ADSB_STATE=state, ADSB_RUN=run,
               ADSB_NO_SYSTEMD="1", ADSB_IWD_DIR=os.path.join(run, "iwd"), **(extra or {}))
    pid, fd = pty.fork()
    if pid == 0:
        os.execve("/bin/bash", ["bash", CONFIG], env)
    import fcntl, struct, termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    screen = pyte.Screen(COLS, ROWS)
    stream = pyte.ByteStream(screen)
    raw = bytearray()      # what the terminal got, to check the OSC 52 copy

    def pump(t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    return
                raw.extend(chunk)
                stream.feed(chunk)
    pump(1.5)
    for k in keys:
        os.write(fd, k)
        pump(0.8)
    pump(0.5)
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    return screen, raw


def draw(screen, path, size=18):
    bold_font = ImageFont.truetype(FONT, size)
    reg_font = ImageFont.truetype(FONT_REG, size) if os.path.exists(FONT_REG) else bold_font
    cw = round(bold_font.getlength("M"))
    ch = round(size * 1.25)
    img = Image.new("RGB", (COLS * cw, ROWS * ch), PALETTE["blue"])
    d = ImageDraw.Draw(img)
    for y in range(ROWS):
        row = screen.buffer[y]
        for x in range(COLS):
            c = row[x]
            fg = color(c.fg, c.bold, PALETTE["white"])
            bg = color(c.bg, False, PALETTE["black"])
            if c.reverse:
                fg, bg = bg, fg
            x0, y0 = x * cw, y * ch
            d.rectangle([x0, y0, x0 + cw - 1, y0 + ch - 1], fill=bg)
            if c.data in "▀▄█":                 # half blocks (the QR code): exact, no gaps between cells
                top = (y0, y0 + ch // 2 - 1)
                bottom = (y0 + ch // 2, y0 + ch - 1)
                for (a, b), on in ((top, c.data in "▀█"), (bottom, c.data in "▄█")):
                    d.rectangle([x0, a, x0 + cw - 1, b], fill=fg if on else bg)
                continue
            if c.data.strip():
                box = c.data in "─│┌┐└┘├┤┬┴┼▒░▓█↑↓"
                if c.data in "─┌┐└┘├┤┬┴┼":      # lines meet the cell edges, whatever the font
                    mx, my = x0 + cw // 2, y0 + ch // 2
                    if c.data in "─┌└├┬┴┼":
                        d.line([mx if c.data in "┌└├" else x0, my, x0 + cw, my], fill=fg)
                    if c.data in "─┐┘┤┬┴┼":
                        d.line([x0, my, mx if c.data in "┐┘┤" else x0 + cw, my], fill=fg)
                    if c.data in "┌┐├┤┬┼":
                        d.line([mx, my, mx, y0 + ch], fill=fg)
                    if c.data in "└┘├┤┴┼":
                        d.line([mx, y0, mx, my], fill=fg)
                    continue
                if c.data == "│":
                    d.line([x0 + cw // 2, y0, x0 + cw // 2, y0 + ch], fill=fg)
                    continue
                f = bold_font if (c.bold or box) else reg_font
                d.text((x0, y0 + (ch - size) // 2 - 1), c.data, font=f, fill=fg)
    img.save(path, optimize=True)


def main():
    for tool in ("whiptail", "jq", "qrencode"):
        if not shutil.which(tool):
            raise SystemExit(f"needs {tool}")
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="adsb-screens-")
    try:
        run = os.path.join(tmp, "run")
        os.makedirs(run)
        shutil.copy(os.path.join(REPO, "server", "tests", "station_aircraft.json"),
                    os.path.join(run, "aircraft.json"))
        with open(os.path.join(run, "stats.json"), "w") as f:
            f.write('{"last1min": {"messages": 31200}}')
        for name, keys, *extra in SCREENS:
            state = os.path.join(tmp, f"{name}.conf")
            with open(state, "w") as f:
                f.write("HOSTNAME=adsb-station\nUSERNAME=adsb\nLAT=-12.9711\nLON=-38.5108\nALT_M=10\n"
                        "GAIN=auto\nBIAS_TEE=no\nWIFI_COUNTRY=BR\nWIFI_SSID=Casa\n")
            path = os.path.join(OUT, f"{name}.png")
            screen, raw = grab(keys, state, run, *extra)
            draw(screen, path)
            if name == "qr":
                import base64
                url = b"http://192.168.1.60/data/aircraft.json"
                assert b"\x1b]52;c;" + base64.b64encode(url) in raw, "no OSC 52 copy of the URL"
            print(path)
        web_page(tmp, run)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def web_page(tmp, run):
    """The station's home page, as adsb-webpage writes it, served with /data/."""
    if not shutil.which("node"):
        print("web.png skipped: no node")
        return
    www = os.path.join(tmp, "www")
    env = dict(os.environ, ADSB_LIB=os.path.join(HERE, "demo.sh"), ADSB_WWW=www, ADSB_NO_SYSTEMD="1")
    subprocess.run(["bash", os.path.join(os.path.dirname(CONFIG), "adsb-webpage")], env=env, check=True)
    shutil.copytree(run, os.path.join(www, "data"))
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass
    handler = functools.partial(Quiet, directory=www)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    path = os.path.join(OUT, "web.png")
    try:
        subprocess.run(["node", os.path.join(HERE, "web.js"), f"http://127.0.0.1:{srv.server_port}/", path],
                       check=True)
        print(path)
    except subprocess.CalledProcessError:
        print("web.png skipped: playwright failed")
    finally:
        srv.shutdown()


if __name__ == "__main__":
    main()
