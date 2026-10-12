#!/bin/sh
# Quad Board client for a jailbroken Kindle Paperwhite (1st gen, FW 5.x).
#
# The Kindle is as dumb as the E1001: it long-polls the server for a version
# number, fetches the ready-made 758x1024 PNG when it moves on and hands it
# to FBInk (or eips). Taps are read raw from the touchscreen and sent back as
# coordinates; the server decides what they mean.
#
#   quad.sh start       stop the Kindle UI and run the board (from KUAL)
#   quad.sh stop        back to the Kindle UI
#   quad.sh touchtest   for 30 s, log taps and show where the server maps them
#   quad.sh diag        log tools, input devices and raw touch events, to debug a new Kindle
#   quad.sh status
#
# Only busybox tools: wget, hexdump/od, awk, dd, lipc-*.

# KUAL may hand us a short PATH: stop/start (upstart) live in /sbin, eips in /usr/sbin
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

EXT=${QUAD_EXT:-/mnt/us/extensions/quadboard}
RUN=${QUAD_RUN:-/var/tmp/quadboard}            # a copy runs from here, so a USB-drive mount can't pull the script away
PIDF=$RUN/quad.pid
LOG=$EXT/quad.log

# tr: a quad.conf saved on Windows (CRLF) would otherwise put a \r in every value
[ -f "$EXT/quad.conf" ] && eval "$(tr -d '\r' < "$EXT/quad.conf")"
: "${SERVER:=http://192.168.1.10:8740}"
: "${TOKEN:=dev}"
: "${POWER:=auto}"                # auto | usb | battery
: "${AWAKE_S:=25}"                # on battery: stay awake this long after a wake or a tap
: "${HOLD_S:=3}"                  # hold a finger this long to quit
: "${GIVEUP_S:=60}"               # no answer from SERVER this long after Start = back to the Kindle (0 = never)
: "${TOUCH_DEV:=}"                # blank = find it
: "${RTC:=}"                      # blank = rtc1 if present, else rtc0

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

# The PW1's busybox ash answers `command -v` with nothing at all, so look on
# PATH ourselves (busybox applets are symlinks there).
have() {
    command -v "$1" >/dev/null 2>&1 && return 0
    _ifs=$IFS; IFS=:
    for _d in $PATH; do
        if [ -x "$_d/$1" ]; then IFS=$_ifs; return 0; fi
    done
    IFS=$_ifs
    return 1
}
where() { have "$1" && { command -v "$1" 2>/dev/null || echo yes; } || echo MISSING; }

# ---------------------------------------------------------------- helpers

# fetch URL OUT SECONDS -- busybox wget may lack -T, so watchdog it ourselves
fetch() {
    wget -q -O "$2" "$1" 2>/dev/null &
    _p=$!
    ( sleep "$3"; kill "$_p" 2>/dev/null ) &
    _w=$!
    wait "$_p"
    _rc=$?
    kill "$_w" 2>/dev/null
    return $_rc
}

nap() { sleep "$1" & _s=$!; wait $_s; }     # a sleep that a TERM can interrupt

FBINK=
for f in /usr/bin/fbink /mnt/us/libkh/bin/fbink /mnt/us/koreader/fbink /mnt/us/usbnet/bin/fbink; do
    [ -x "$f" ] && FBINK=$f && break
done

show() {   # show PNG FULL(0|1)
    if [ -n "$FBINK" ]; then
        if [ "$2" = 1 ]; then "$FBINK" -q -f -g file="$1"; else "$FBINK" -q -g file="$1"; fi
    else
        if [ "$2" = 1 ]; then eips -f -g "$1" >/dev/null; else eips -g "$1" >/dev/null; fi
    fi
}

say() {    # a line of text at the bottom, for errors before the first frame
    if [ -n "$FBINK" ]; then "$FBINK" -q -y -2 -m "$*"; else eips 1 38 "$* " >/dev/null; fi
}

battery() {
    b=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    [ -z "$b" ] && b=$(cat /sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity 2>/dev/null | tr -dc 0-9)
    echo "${b:-0}"
}

# the charger's own flag (PW1: aplite_charger, per KOReader), then powerd's
CHARGING_FILES="/sys/devices/platform/aplite_charger.0/charging /sys/devices/platform/fsl-usb2-udc/charging
/sys/devices/system/wario_charger/wario_charger0/charging"

power_why() {   # one line for the log: what on_usb looked at
    w="POWER=$POWER batt=$(battery)% lipc.isCharging=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)"
    for f in $CHARGING_FILES; do [ -r "$f" ] && w="$w ${f##*/platform/}=$(cat "$f")"; done
    echo "$w"
}

on_usb() {
    case "$POWER" in usb) return 0 ;; battery) return 1 ;; esac
    for f in $CHARGING_FILES; do
        [ -r "$f" ] && [ "$(cat "$f" 2>/dev/null)" = 1 ] && return 0
    done
    [ "$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)" = 1 ] && return 0
    # a full battery stops "charging" while still plugged in
    [ "$(battery)" -ge 100 ] 2>/dev/null && return 0
    return 1
}

find_touch() {
    [ -n "$TOUCH_DEV" ] && { echo "$TOUCH_DEV"; return; }
    # 1) an input device whose name looks like a touchscreen
    d=$(awk '/^N: Name=/ { t = tolower($0) ~ /zforce|touch|cyttsp|pt_mt|elan/ }
         t && /^H: Handlers=/ { for (i = 1; i <= NF; i++) if ($i ~ /^event[0-9]+$/) { print "/dev/input/" $i; exit } }' \
        /proc/bus/input/devices 2>/dev/null | head -n 1)
    [ -n "$d" ] && [ -e "$d" ] && { echo "$d"; return; }
    # 2) the first one with absolute axes: a touchscreen has them, buttons don't
    for e in /sys/class/input/event*; do
        abs=$(cat "$e/device/capabilities/abs" 2>/dev/null)
        case "$abs" in "" | 0) continue ;; esac
        [ -e "/dev/input/${e##*/}" ] && { echo "/dev/input/${e##*/}"; return; }
    done
    # 3) KOReader's choice for the PW1
    echo /dev/input/event0
}

input_names() {
    sed -n 's/^N: Name="\(.*\)"/\1/p' /proc/bus/input/devices 2>/dev/null | tr '\n' ',' | sed 's/,$//'
}

wifi_up() {   # wait up to $1 s for Wi-Fi
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
    i=0
    while [ $i -lt "$1" ]; do
        [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = CONNECTED ] && return 0
        nap 1
        i=$((i + 1))
    done
    return 1
}

suspend_for() {   # deep sleep, woken by the RTC
    r=$RTC
    [ -z "$r" ] && { [ -e /sys/class/rtc/rtc1/wakealarm ] && r=rtc1 || r=rtc0; }
    log "sleeping $1 s ($r)"
    echo 0 > "/sys/class/rtc/$r/wakealarm" 2>/dev/null
    if echo "+$1" > "/sys/class/rtc/$r/wakealarm" 2>/dev/null; then
        echo mem > /sys/power/state 2>/dev/null || nap "$1"
    else
        nap "$1"                 # no RTC alarm: just idle
    fi
    wifi_up 30 || log "wifi did not come back"
}

# ---------------------------------------------------------------- touch

# Raw input events, 16 bytes each on this 32-bit kernel: timeval(8) type(2)
# code(2) value(4), printed as 8 unsigned 16-bit words. awk keeps the finger
# state between reads and prints "UP x y seconds_held" when it lifts.
TOUCH_AWK='
# state across reads: down x y ts explicit framepos
#   explicit = the device says when a finger lifts (MT protocol B tracking id,
#              BTN_TOUCH or pressure); otherwise it is MT protocol A, where a
#              report frame with no contact in it means the finger lifted
BEGIN { split(st, a, " "); down = a[1]; x = a[2]; y = a[3]; ts = a[4]; explicit = a[5]; fp = a[6] }
function lift() { if (down) printf "UP %d %d %.2f\n", x, y, t - ts; down = 0 }
function press() { if (!down) { down = 1; ts = t } }
NF >= 8 {
    o = NF - 8
    t = ($(o+1) + $(o+2) * 65536) + ($(o+3) + $(o+4) * 65536) / 1000000
    type = $(o+5); code = $(o+6); v = $(o+7) + $(o+8) * 65536
    if (v >= 2147483648) v -= 4294967296
    if (type == 3) {
        if (code == 53 || code == 0) { x = v; fp = 1; if (!explicit) press() }
        else if (code == 54 || code == 1) { y = v; fp = 1; if (!explicit) press() }
        else if (code == 48 || code == 50 || code == 58) fp = 1      # touch major / width / MT pressure: a contact
        else if (code == 57 || code == 24) {            # tracking id (-1 = lifted) / pressure (0 = lifted)
            explicit = 1
            if ((code == 57 && v < 0) || (code == 24 && v == 0)) lift(); else press()
        }
    } else if (type == 1 && code == 330) {              # BTN_TOUCH
        explicit = 1
        if (v) press(); else lift()
    } else if (type == 0 && code == 0) {                # SYN_REPORT: end of a frame
        if (!explicit && !fp) lift()
        fp = 0
    }
}
END { printf "STATE %d %d %d %.3f %d %d\n", down, x, y, ts, explicit, fp }'

# Binary events -> "8 unsigned 16-bit words" per line. Which tool can do
# that differs per firmware (the PW1's busybox has no od, maybe no hexdump),
# so pick_words tries each one on a known sample and keeps the first that
# gets it right.
B64_AWK='
BEGIN { a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for (i = 0; i < 64; i++) val[substr(a, i + 1, 1)] = i; n = 0; acc = 0; bits = 0
        pw[0] = 1; for (i = 1; i < 16; i++) pw[i] = pw[i - 1] * 2 }      # no ^: busybox awk may lack math
/^begin/ || /^====/ { next }
{ for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "=") { acc = 0; bits = 0; continue }
      if (!(c in val)) continue
      acc = acc * 64 + val[c]; bits += 6
      if (bits >= 8) { bits -= 8; p = pw[bits]; by[n++] = int(acc / p) % 256; acc = acc % p }
  } }
END { for (i = 0; i + 15 < n; i += 16) {
          l = ""; for (j = 0; j < 16; j += 2) l = l (j ? " " : "") (by[i + j] + by[i + j + 1] * 256)
          print l } }'
# cmp -l lists only the bytes that differ from /dev/zero: offset (1-based) and octal value
CMP_AWK='
function oct(s,  r, k) { r = 0; for (k = 1; k <= length(s); k++) r = r * 8 + substr(s, k, 1); return r }
$1 ~ /^[0-9]+$/ { by[$1 - 1] = oct($2) }
END { for (i = 0; i + 15 < n; i += 16) {
          l = ""; for (j = 0; j < 16; j += 2) l = l (j ? " " : "") (by[i + j] + by[i + j + 1] * 256)
          print l } }'

words_with() {
    case "$1" in
        hexdump) hexdump -v -e '8/2 "%u " "\n"' ;;
        bb-hexdump) busybox hexdump -v -e '8/2 "%u " "\n"' ;;
        od) od -v -t u2 ;;
        od-d) od -v -d ;;
        bb-od) busybox od -v -t u2 ;;
        base64) base64 | awk "$B64_AWK" ;;
        bb-base64) busybox base64 | awk "$B64_AWK" ;;
        uuencode) uuencode -m - | awk "$B64_AWK" ;;
        bb-uuencode) busybox uuencode -m - | awk "$B64_AWK" ;;
        cmp) cat > "$RUN/chunk.bin"
             cmp -l "$RUN/chunk.bin" /dev/zero 2>/dev/null | awk -v n="$(wc -c < "$RUN/chunk.bin")" "$CMP_AWK" ;;
        bb-cmp) cat > "$RUN/chunk.bin"
             busybox cmp -l "$RUN/chunk.bin" /dev/zero 2>/dev/null | awk -v n="$(wc -c < "$RUN/chunk.bin")" "$CMP_AWK" ;;
    esac
}

WORDS=
pick_words() {
    mkdir -p "$RUN"
    # two events' worth: 1..7 and 65535 (unsigned!), then 0s and 258
    printf '\001\000\002\000\003\000\004\000\005\000\006\000\007\000\377\377\000\000\000\000\000\000\000\000\000\000\000\000\000\000\002\001' \
        > "$RUN/probe.bin"
    want="1 2 3 4 5 6 7 65535|0 0 0 0 0 0 0 258|"
    for m in hexdump bb-hexdump od od-d bb-od base64 bb-base64 uuencode bb-uuencode cmp bb-cmp; do
        got=$(words_with "$m" < "$RUN/probe.bin" 2>/dev/null |
              awk 'NF >= 8 { o = NF - 8; printf "%s %s %s %s %s %s %s %s|", $(o+1), $(o+2), $(o+3), $(o+4), $(o+5), $(o+6), $(o+7), $(o+8) }')
        if [ "$got" = "$want" ]; then WORDS=$m; return 0; fi
    done
    return 1
}

words() { words_with "$WORDS"; }

# touch_loop DEV ACTION -- ACTION is "run" (send taps) or "test" (dry-run, log only)
touch_loop() {
    if [ -z "$WORDS" ] && ! pick_words; then
        log "no tool here can decode touch events (tried hexdump, od, base64, uuencode, cmp); taps won't work"
        return 1
    fi
    exec 3< "$1"
    st="0 0 0 0 0 0"
    while :; do
        out=$(dd bs=1024 count=1 <&3 2>/dev/null | words | awk -v st="$st" "$TOUCH_AWK")
        st=$(echo "$out" | sed -n 's/^STATE //p')
        echo "$out" | grep '^UP ' | while read -r _ x y held; do
            if [ "$2" = test ]; then
                z=$(wget -q -O - "$SERVER/api/kindle/tap?k=$TOKEN&x=$x&y=$y&dry=1" 2>/dev/null)
                log "touchtest: raw $x,$y held ${held}s -> $z"
            elif awk "BEGIN { exit !($held >= $HOLD_S) }"; then
                log "long press: quitting"
                kill -TERM "$(cat "$PIDF")" 2>/dev/null
            else
                log "tap $x,$y"
                date +%s > "$RUN/lasttap"
                fetch "$SERVER/api/kindle/tap?k=$TOKEN&x=$x&y=$y" /dev/null 20 &
            fi
        done
    done
}

# ---------------------------------------------------------------- main loop

framework_stop() {
    # the UI's teardown TERMs its process group, which can include us (KUAL);
    # run() already ignores TERM until this is done
    if stop lab126_gui >> "$LOG" 2>&1; then
        log "kindle UI stopped (lab126_gui)"
    elif stop framework >> "$LOG" 2>&1; then
        log "kindle UI stopped (framework)"
    elif [ -x /etc/init.d/framework ] && /etc/init.d/framework stop >> "$LOG" 2>&1; then
        log "kindle UI stopped (init.d)"
    else
        log "could NOT stop the kindle UI (stop: $(where stop))"
    fi
    usleep 1500000 2>/dev/null || sleep 2
}

framework_start() {
    start lab126_gui 2>/dev/null || start framework 2>/dev/null || /etc/init.d/framework start 2>/dev/null
}

cleanup() {
    trap - TERM INT HUP
    log "stopping"
    kill "$TPID" "$_p" "$_w" "$_s" 2>/dev/null     # touch reader, in-flight wget + watchdog, a nap
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    rm -f "$PIDF" "$RUN/lasttap"
    eips -c >/dev/null 2>&1
    framework_start
    exit 0
}

run() {
    trap "" TERM HUP        # survive KUAL closing and the UI shutting down; cleanup takes over below
    echo $$ > "$PIDF"
    log "starting: server $SERVER, fbink ${FBINK:-none (eips: $(where eips))}"
    log "input devices: $(input_names)"
    dev=$(find_touch)
    # without a touchscreen there'd be no way back (taps and the long press
    # both need it), so check it before taking the Kindle UI away
    # (a subshell: a failed redirection on exec would end this whole script)
    if ! ( : < "$dev" ) 2>/dev/null; then
        log "can't open touchscreen $dev: NOT starting (set TOUCH_DEV in quad.conf, see Diagnostics)"
        rm -f "$PIDF"
        exit 1
    fi
    # ...and that something here can decode its events (the PW1 has no od)
    if ! pick_words; then
        log "no tool here can decode touch events (tried hexdump, od, base64, uuencode, cmp): NOT starting"
        rm -f "$PIDF"
        exit 1
    fi
    log "touch: $dev, events decoded with $WORDS"
    log "power: $(power_why)"
    framework_stop
    trap cleanup TERM INT HUP
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
    eips -c >/dev/null 2>&1
    say "Quad Board: connecting to $SERVER"
    wifi_up 30 || log "no wifi yet"
    touch_loop "$dev" run &
    TPID=$!

    # A wrong SERVER would otherwise leave a blank screen with the Kindle UI
    # gone. Keep trying /healthz for GIVEUP_S, then hand the Kindle back.
    # (A long press still quits while we wait.)
    if [ "$GIVEUP_S" -gt 0 ] 2>/dev/null; then
        t0=$(date +%s)
        until fetch "$SERVER/healthz" "$RUN/healthz" 10 && grep -q ok "$RUN/healthz" 2>/dev/null; do
            if [ $(($(date +%s) - t0)) -ge "$GIVEUP_S" ]; then
                log "no answer from $SERVER in ${GIVEUP_S}s: check SERVER in quad.conf; back to the Kindle"
                say "Quad Board: $SERVER not answering. Check quad.conf."
                nap 5
                cleanup
            fi
            nap 5
        done
        log "server $SERVER answered"
    fi

    V=0; BOOT=1; FAILS=0
    woke=$(date +%s)
    while :; do
        if on_usb; then usb=1; else usb=0; fi
        if [ "$usb" != "${lastusb:-}" ]; then
            log "power: $([ $usb = 1 ] && echo USB, staying awake || echo battery, sleeping between updates) ($(power_why))"
            lastusb=$usb
        fi
        now=$(date +%s)
        last=$(cat "$RUN/lasttap" 2>/dev/null || echo 0)
        [ "$last" -gt "$woke" ] 2>/dev/null && woke=$last
        if [ $usb = 1 ]; then wait_s=50; else wait_s=$((woke + AWAKE_S - now)); [ $wait_s -lt 0 ] && wait_s=0; fi

        if fetch "$SERVER/api/kindle/poll?k=$TOKEN&v=$V&wait=$wait_s&batt=$(battery)&usb=$usb${BOOT:+&boot=1}" \
                 "$RUN/meta" $((wait_s + 20)) && read -r NV FULL SLEEP < "$RUN/meta" && [ -n "$NV" ]; then
            FAILS=0; BOOT=
            if [ "$NV" != "$V" ]; then
                if fetch "$SERVER/api/kindle/frame.png?k=$TOKEN" "$RUN/frame.png" 40; then
                    show "$RUN/frame.png" "$FULL"
                    V=$NV
                fi
            fi
        else
            FAILS=$((FAILS + 1))
            log "server unreachable ($FAILS)"
            [ $FAILS = 3 ] && say "Quad Board: can't reach $SERVER"
            [ $FAILS -ge 3 ] && ! wifi_up 5 && log "wifi down"
            SLEEP=0
            [ $usb = 0 ] && [ $FAILS -ge 3 ] && SLEEP=600   # on battery, don't burn it retrying
            nap 10
        fi

        # on battery, once the awake window is over, sleep until the next scheduled update
        if [ $usb = 0 ] && [ "${SLEEP:-0}" -gt 0 ] && [ $(($(date +%s) - woke)) -ge "$AWAKE_S" ]; then
            suspend_for "$SLEEP"
            woke=$(date +%s)
        fi
    done
}

running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

case "$1" in
    start)
        running && { log "already running"; exit 0; }
        log "start requested"
        if ! { mkdir -p "$RUN" && cp "$0" "$RUN/quad.sh"; }; then
            log "can't copy the script to $RUN"
            exit 1
        fi
        # a session of its own if we can, so KUAL closing its menu can't take us
        # down with it. The PW1's busybox has neither setsid nor nohup; a plain
        # background job is fine there, since run() ignores TERM/HUP from its
        # first line. (Ignoring them here instead would stick: a shell can't
        # re-trap signals that were ignored when it started, and Stop needs TERM.)
        if have setsid; then
            setsid sh "$RUN/quad.sh" run >> "$LOG" 2>&1 < /dev/null &
        elif have nohup; then
            nohup sh "$RUN/quad.sh" run >> "$LOG" 2>&1 < /dev/null &
        else
            sh "$RUN/quad.sh" run >> "$LOG" 2>&1 < /dev/null &
        fi
        sleep 2
        running || log "the board process exited right away; see the lines above"
        ;;
    run)
        mkdir -p "$RUN"
        run
        ;;
    stop)
        running && kill -TERM "$(cat "$PIDF")"
        ;;
    touchtest)
        mkdir -p "$RUN"
        dev=$(find_touch)
        log "touchtest on $dev for 30 s: tap the left, middle and right of the screen (held landscape)"
        touch_loop "$dev" test &
        tp=$!
        sleep 30
        kill $tp 2>/dev/null
        log "touchtest done"
        ;;
    diag)
        # everything needed to debug a new Kindle, appended to quad.log
        mkdir -p "$RUN"
        log "=== diag: PATH=$PATH"
        for t in sh busybox wget hexdump od awk dd sed tr setsid nohup start-stop-daemon usleep eips fbink \
                 lipc-get-prop lipc-set-prop stop start initctl; do
            log "  $t: $(where "$t")"
        done
        log "  fbink in use: ${FBINK:-none}"
        for bb in busybox /bin/busybox /usr/bin/busybox; do
            l=$($bb --list 2>/dev/null | tr '\n' ' ')
            [ -n "$l" ] && { log "  busybox applets ($bb): $l"; break; }
        done
        if pick_words; then log "  touch decoder: $WORDS"; else log "  touch decoder: NONE works"; fi
        log "  kindle UI jobs: $(initctl list 2>/dev/null | grep -iE 'lab126_gui|framework' | tr '\n' ';')"
        log "  battery $(battery)%, charging=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null), wifi=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)"
        log "  server: $(wget -q -O - "$SERVER/healthz" 2>&1 | head -c 80)"
        log "  rtc: $(echo /sys/class/rtc/rtc*)"
        log "  input devices:"
        sed -n '/^[NH]:/p' /proc/bus/input/devices 2>/dev/null | while read -r ln; do log "    $ln"; done
        dev=$(find_touch)
        log "  touch device picked: $dev; raw events for 10 s, tap the screen a few times:"
        dd if="$dev" of="$RUN/raw.bin" bs=16 count=200 2>/dev/null &
        dp=$!
        sleep 10
        kill $dp 2>/dev/null
        log "  $(wc -c < "$RUN/raw.bin" 2>/dev/null || echo 0) bytes; first events (sec usec type code value as 8 words):"
        [ -n "$WORDS" ] && words < "$RUN/raw.bin" 2>/dev/null | head -n 40 | while read -r ln; do log "    $ln"; done
        log "=== diag done"
        ;;
    status)
        running && echo "running (pid $(cat "$PIDF"))" || echo "stopped"
        tail -n 15 "$LOG" 2>/dev/null
        ;;
    *)
        echo "usage: $0 start|stop|touchtest|diag|status"
        exit 1
        ;;
esac
