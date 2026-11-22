# shellcheck shell=bash
# Shared by adsb-firstboot and adsb-config. The station's settings live in
# /etc/adsb-station.conf (KEY=VALUE); /etc/default/readsb is generated from it.

STATE=${ADSB_STATE:-/etc/adsb-station.conf}
NO_SYSTEMD=${ADSB_NO_SYSTEMD:-}       # set in container tests, which have no systemd
IWD_DIR=${ADSB_IWD_DIR:-/var/lib/iwd}

# ---------------------------------------------------------------- state file
state_get() {    # state_get KEY [default]
    local v
    v=$(sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1)
    echo "${v:-${2:-}}"
}

state_set() {    # state_set KEY VALUE
    touch "$STATE"
    if grep -q "^$1=" "$STATE"; then
        local tmp
        tmp=$(mktemp)
        awk -v k="$1" -v v="$2" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' "$STATE" > "$tmp"
        cat "$tmp" > "$STATE"
        rm -f "$tmp"
    else
        echo "$1=$2" >> "$STATE"
    fi
}

svc() {          # systemctl, or nothing where there is no systemd
    [[ -n $NO_SYSTEMD ]] && return 0
    systemctl "$@"
}

# ---------------------------------------------------------------- validation
is_lat()  { [[ $1 =~ ^-?[0-9]{1,2}(\.[0-9]+)?$ ]] && awk -v x="$1" 'BEGIN { exit !(x >= -90 && x <= 90) }'; }
is_lon()  { [[ $1 =~ ^-?[0-9]{1,3}(\.[0-9]+)?$ ]] && awk -v x="$1" 'BEGIN { exit !(x >= -180 && x <= 180) }'; }
is_alt()  { [[ $1 =~ ^-?[0-9]{1,4}(\.[0-9]+)?$ ]]; }
is_gain() {       # auto, or dB within the R820T/R828D range (readsb picks the nearest step)
    [[ $1 =~ ^(auto|auto-verbose)$ ]] && return 0
    [[ $1 =~ ^[0-9]{1,2}(\.[0-9])?$ ]] && awk -v x="$1" 'BEGIN { exit !(x >= 0 && x <= 49.6) }'
}
is_host() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]; }
is_country() { [[ $1 =~ ^[A-Z]{2}$ ]]; }

# ---------------------------------------------------------------- readsb
render_readsb() {
    local lat lon gain receiver decoder
    lat=$(state_get LAT) lon=$(state_get LON) gain=$(state_get GAIN auto)
    receiver="--device-type rtlsdr --gain $gain --ppm $(state_get PPM 0)"
    [[ $(state_get BIAS_TEE no) == yes ]] && receiver+=" --enable-biastee"
    decoder="--max-range 450 --write-json-every 1"
    [[ -n $lat && -n $lon ]] && decoder+=" --lat $lat --lon $lon"
    cat > /etc/default/readsb <<EOF
# Generated from /etc/adsb-station.conf: change settings with  sudo adsb-config
RECEIVER_OPTIONS="$receiver"
DECODER_OPTIONS="$decoder"
NET_OPTIONS="--net --net-ri-port 30001 --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004,30104 --net-bo-port 30005"
JSON_OPTIONS="--json-location-accuracy 2 --range-outline-hours 24"
EOF
}

restart_readsb() {
    render_readsb
    if svc is-enabled --quiet readsb 2>/dev/null; then svc restart readsb; fi
}

set_location() {  # set_location LAT LON [ALT_M]
    is_lat "$1" || { echo "latitude inválida: $1 (graus decimais, -90 a 90)"; return 2; }
    is_lon "$2" || { echo "longitude inválida: $2 (graus decimais, -180 a 180)"; return 2; }
    [[ -z ${3:-} ]] || is_alt "$3" || { echo "altitude inválida: $3 (metros)"; return 2; }
    state_set LAT "$1"
    state_set LON "$2"
    [[ -n ${3:-} ]] && state_set ALT_M "$3"
    restart_readsb
}

set_radio() {     # set_radio GAIN yes|no [PPM]
    is_gain "$1" || { echo "ganho inválido: $1 (auto, ou de 0 a 49.6 dB)"; return 2; }
    [[ $2 == yes || $2 == no ]] || { echo "bias-tee: yes ou no"; return 2; }
    [[ -z ${3:-} || $3 =~ ^-?[0-9]{1,3}$ ]] || { echo "ppm inválido: $3"; return 2; }
    state_set GAIN "$1"
    state_set BIAS_TEE "$2"
    [[ -n ${3:-} ]] && state_set PPM "$3"
    restart_readsb
}

set_hostname() {
    is_host "$1" || { echo "nome inválido: $1 (letras, números e hífen)"; return 2; }
    echo "$1" > /etc/hostname
    hostname "$1" 2>/dev/null || true
    touch /etc/hosts
    sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
    printf '127.0.1.1\t%s\n' "$1" >> /etc/hosts
    state_set HOSTNAME "$1"
    svc restart avahi-daemon 2>/dev/null || true
}

# ---------------------------------------------------------------- Wi-Fi (iwd + systemd-networkd)
wifi_iface() {    # the first wireless interface, if a supported adapter is plugged in
    local d
    for d in /sys/class/net/*; do
        [[ -d $d/wireless || -e $d/phy80211 ]] && { basename "$d"; return 0; }
    done
    return 1
}

iwd_name() {      # iwd's file name for an SSID: as is if plain, else "=" + hex
    if [[ $1 =~ ^[A-Za-z0-9_\ -]+$ ]]; then
        echo "$1"
    else
        printf '=%s' "$(printf %s "$1" | od -An -tx1 | tr -d ' \n')"
    fi
}

set_country() {   # regulatory domain: which channels and power are legal here
    set -- "${1^^}"
    is_country "$1" || { echo "país inválido: $1 (código de 2 letras, ex.: BR)"; return 2; }
    echo "options cfg80211 ieee80211_regdom=$1" > /etc/modprobe.d/adsb-wifi-country.conf
    state_set WIFI_COUNTRY "$1"
    if command -v iw >/dev/null; then iw reg set "$1" 2>/dev/null || true; fi
}

set_wifi() {      # set_wifi SSID [PASSPHRASE] [hidden]
    local ssid=$1 psk=${2:-} hidden=${3:-} base
    [[ -n $ssid && ${#ssid} -le 32 ]] || { echo "SSID vazio ou com mais de 32 caracteres"; return 2; }
    if [[ -n $psk ]] && { [[ ${#psk} -lt 8 || ${#psk} -gt 63 ]] || [[ $psk == *$'\n'* ]]; }; then
        echo "a senha do Wi-Fi (WPA) tem de 8 a 63 caracteres"; return 2
    fi
    base=$IWD_DIR/$(iwd_name "$ssid")
    install -d -m 700 "$IWD_DIR"
    rm -f "$base.psk" "$base.open"
    if [[ -n $psk ]]; then
        { echo "[Security]"; echo "Passphrase=$psk"; } > "$base.psk"
    else
        : > "$base.open"
    fi
    local f=$base.psk
    [[ -n $psk ]] || f=$base.open
    {
        echo "[Settings]"
        echo "AutoConnect=true"
        if [[ $hidden == hidden ]]; then echo "Hidden=true"; fi
    } >> "$f"
    chmod 600 "$f"
    state_set WIFI_SSID "$ssid"
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/20-wifi-dhcp.network <<'EOF'
# Wi-Fi (USB adapter) via iwd; addresses by DHCP, like the cable (10-en-dhcp.network).
# Metric above the cable's default 1024, so the cable wins when both are up.
[Match]
Name=wl*

[Network]
DHCP=yes

[DHCPv4]
RouteMetric=2048
EOF
    svc disable --now wpa_supplicant 2>/dev/null || true    # iwd and wpa_supplicant must not share the adapter
    svc enable iwd
    svc restart iwd
    svc restart systemd-networkd
}

wifi_off() {
    rm -f "$IWD_DIR"/*.psk "$IWD_DIR"/*.open /etc/systemd/network/20-wifi-dhcp.network
    state_set WIFI_SSID ""
    svc disable --now iwd 2>/dev/null || true
    svc restart systemd-networkd 2>/dev/null || true
}

wifi_scan() {     # "signal<TAB>ssid" lines, strongest first (needs the adapter and iwd)
    local ifc
    ifc=$(wifi_iface) || return 1
    ip link set "$ifc" up 2>/dev/null || true
    if command -v iwctl >/dev/null && svc is-active --quiet iwd 2>/dev/null; then
        iwctl station "$ifc" scan 2>/dev/null || true
        sleep 4
        iw dev "$ifc" scan dump 2>/dev/null       # what iwd just scanned, without a second scan
    else
        iw dev "$ifc" scan 2>/dev/null
    fi | awk '/^BSS / { s = "" } /signal:/ { s = $2 } /^\tSSID: / { sub(/^\tSSID: /, ""); if ($0 != "") print s "\t" $0 }' \
       | sort -t$'\t' -k1,1 -rn | awk -F'\t' '!seen[$2]++'
}
