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

if command -v hexdump >/dev/null 2>&1; then
    words() { hexdump -v -e '8/2 "%u " "\n"'; }
else
    words() { od -v -d; }        # offset column + 8 words; awk takes the last 8
fi

# touch_loop DEV ACTION -- ACTION is "run" (send taps) or "test" (dry-run, log only)
touch_loop() {
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
        log "could NOT stop the kindle UI (stop: $(command -v stop || echo missing))"
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
    log "starting: server $SERVER, fbink ${FBINK:-none (eips: $(command -v eips || echo missing))}"
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
    log "touch: $dev"
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
        if command -v setsid >/dev/null 2>&1; then
            setsid sh "$RUN/quad.sh" run >> "$LOG" 2>&1 < /dev/null &
        elif command -v nohup >/dev/null 2>&1; then
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
            log "  $t: $(command -v "$t" || echo MISSING)"
        done
        log "  fbink in use: ${FBINK:-none}"
        log "  kindle UI jobs: $(initctl list 2>/dev/null | grep -iE 'lab126_gui|framework' | tr '\n' ';')"
        log "  battery $(battery)%, charging=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null), wifi=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)"
        log "  server: $(wget -q -O - "$SERVER/healthz" 2>&1 | head -c 80)"
        log "  rtc: $(echo /sys/class/rtc/rtc*)"
        log "  input devices:"
        grep -E '^(N|H):' /proc/bus/input/devices 2>/dev/null | while read -r ln; do log "    $ln"; done
        dev=$(find_touch)
        log "  touch device picked: $dev; raw events for 10 s, tap the screen a few times:"
        dd if="$dev" of="$RUN/raw.bin" bs=16 count=200 2>/dev/null &
        dp=$!
        sleep 10
        kill $dp 2>/dev/null
        log "  $(wc -c < "$RUN/raw.bin" 2>/dev/null || echo 0) bytes; first events (sec usec type code value as 8 words):"
        words < "$RUN/raw.bin" 2>/dev/null | head -n 40 | while read -r ln; do log "    $ln"; done
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
