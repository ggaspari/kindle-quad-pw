# shellcheck shell=bash
# Sample data for the README screenshots (station/screens/capture.py): the
# real adsb-config menus, with the hardware and the system writes swapped for
# a pretend station. Nothing here touches the machine running it.
# shellcheck source=station/rootfs/usr/local/lib/adsb-station/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../rootfs/usr/local/lib/adsb-station/common.sh"

# writes: only the demo state file changes
render_readsb() { :; }
restart_readsb() { :; }
set_hostname() { state_set HOSTNAME "$1"; }
set_country() { state_set WIFI_COUNTRY "${1^^}"; }
set_wifi() { state_set WIFI_SSID "$1"; }
wifi_off() { state_set WIFI_SSID ""; }

# hardware: an RTL-SDR Blog V3 (as its USB descriptor names itself), a USB Wi-Fi adapter and a few networks around
sdr_present() { echo "Realtek RTL2838UHIDIR"; }
wifi_iface() { echo wlx00e04c81920a; }
wifi_scan() {
    printf '%s\t%s\n' -41.00 "Casa" -55.00 "Casa 5G" -68.00 "Vizinho_2G" -74.00 "NET_2G4F1C" -82.00 "iPhone de Ana"
}
hostname() { echo adsb-station; }
ip() {
    case "$*" in
        *"addr show scope global"*)
            echo "2: end0    inet 192.168.1.60/24 brd 192.168.1.255 scope global dynamic end0"
            echo "3: wlx00e04c81920a    inet 192.168.1.61/24 brd 192.168.1.255 scope global dynamic wlx00e04c81920a" ;;
    esac
}
iw() { printf 'Connected to 9c:53:22:aa:10:4e (on wlx00e04c81920a)\n\tSSID: Casa\n'; }
# the tar1090 map: installed unless DEMO_MAP=no (the screen that offers to install it)
map_installed() { [[ ${DEMO_MAP:-yes} == yes ]]; }
