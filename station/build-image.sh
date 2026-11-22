#!/bin/bash
# Builds the ADS-B station SD card image for the Libre Computer "Le Potato"
# (AML-S905X-CC) with an RTL-SDR, from Libre Computer's official Debian 12 image.
#
#   sudo station/build-image.sh [work dir]     -> <work dir>/out/adsb-station-lepotato-*.img.xz
#
# Nothing is mounted and nothing arm64 runs here, so it works in an unprivileged
# container (it does need root, to keep file owners): the btrfs root is read
# out with `btrfs restore`, the station files are added, and it is written back
# with `mkfs.btrfs --rootdir` under the same UUID GRUB looks for. The board does
# the rest at first boot (rootfs/usr/local/sbin/adsb-firstboot), offline, with
# the arm64 packages and pinned sources this script puts in /opt/adsb-station.
#
# Needs: btrfs-progs >= 6, mtools, xz-utils, fdisk (sfdisk), apt, git, curl.
set -euo pipefail

BASE_URL="https://distro.libre.computer/ci/debian/12/debian-12-base-arm64%2Baml-s905x-cc.img.xz"
BASE_SHA256="ffae0d7b42c02ed496f9ec6ad6f3b6eb74dbad1dc3849441f826203e8fa6e7c0"   # 2024-01-25 build
ROOT_MB=${ROOT_MB:-3072}       # root partition in the image; growroot fills the SD card at first boot

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(realpath -m "${1:-$HERE/work}")
OUT=$WORK/out
STAMP=$(date +%Y%m%d)
NAME=adsb-station-lepotato-$STAMP

[[ $EUID -eq 0 ]] || { echo "run as root (file owners in the image must stay root)"; exit 1; }
for t in btrfs mkfs.btrfs mcopy xz sfdisk apt-get git curl sha256sum; do
    command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }
done
export MTOOLS_SKIP_CHECK=1
mkdir -p "$WORK" "$OUT"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------- base image
BASE_XZ=$WORK/base.img.xz
if ! echo "$BASE_SHA256  $BASE_XZ" | sha256sum -c --quiet 2>/dev/null; then
    log "downloading the base image (1.5 GB)"
    curl -fL --retry 3 -o "$BASE_XZ.part" "$BASE_URL"
    mv "$BASE_XZ.part" "$BASE_XZ"
    echo "$BASE_SHA256  $BASE_XZ" | sha256sum -c --quiet
fi
log "decompressing"
xz -dc -T0 "$BASE_XZ" > "$WORK/base.img"

# partition 1: FAT (EFI + GRUB, mounted at /boot/efi); partition 2: btrfs root.
# u-boot lives in the gap before partition 1 and is copied over untouched.
part() {    # "<start> <size>" in sectors of partition $1
    sfdisk -d "$WORK/base.img" | sed -n "s/^[^ ]*[^0-9]$1 : start= *\([0-9]*\), size= *\([0-9]*\).*/\1 \2/p"
}
read -r P1_START _ < <(part 1) || true
read -r P2_START P2_SIZE < <(part 2) || true
[[ -n ${P2_START:-} && -n ${P1_START:-} ]] || { echo "unexpected partition table"; sfdisk -d "$WORK/base.img"; exit 1; }
log "p1 at sector $P1_START, p2 at sector $P2_START ($((P2_SIZE / 2048)) MB)"

# ---------------------------------------------------------------- root tree
ROOTFS=$WORK/rootfs
if [[ -e $ROOTFS ]]; then
    echo "$ROOTFS exists from an earlier run; remove it first"; exit 1
fi
dd if="$WORK/base.img" of="$WORK/root-base.btrfs" bs=512 skip="$P2_START" count="$P2_SIZE" status=none
FSID=$(btrfs inspect-internal dump-super "$WORK/root-base.btrfs" | awk '$1 == "fsid" {print $2}')
LABEL=$(btrfs inspect-internal dump-super "$WORK/root-base.btrfs" | awk '$1 == "label" {print $2}')
log "root btrfs: label=$LABEL uuid=$FSID"
grep -q "$FSID" <(mtype -i "$WORK/base.img@@$((P1_START * 512))" ::/EFI/debian/grub.cfg) \
    || { echo "GRUB does not look for $FSID; the image layout changed"; exit 1; }

log "reading the root filesystem out (btrfs restore)"
mkdir "$ROOTFS"
btrfs restore -i -S -x -m "$WORK/root-base.btrfs" "$ROOTFS" > "$WORK/restore.log" 2>&1
if grep -qi "error" "$WORK/restore.log"; then
    grep -i error "$WORK/restore.log" | head; echo "btrfs restore reported errors"; exit 1
fi
rm -f "$WORK/root-base.btrfs"

# ---------------------------------------------------------------- station files
log "adding the station files"
# owned by root whoever checked the repo out, and without touching the
# owner or mode of directories the image already has (/etc, /usr/local, ...)
tar -C "$HERE/rootfs" --owner=0 --group=0 --mode=go-w -c . | tar -C "$ROOTFS" --no-overwrite-dir -x
chmod 755 "$ROOTFS/usr/local/sbin/adsb-firstboot"
ln -sf /etc/systemd/system/adsb-firstboot.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/adsb-firstboot.service"
PAYLOAD=$ROOTFS/opt/adsb-station
mkdir -p "$PAYLOAD/debs" "$PAYLOAD/src"
cp "$HERE/packages.txt" "$HERE/sources.lock" "$PAYLOAD/"

log "downloading the arm64 packages the image lacks"
APT=$WORK/apt
mkdir -p "$APT/lists/partial" "$APT/archives/partial" "$APT/empty"
KEYRING=$ROOTFS/usr/share/keyrings/debian-archive-keyring.gpg
cat > "$APT/sources.list" <<EOF
deb [signed-by=$KEYRING] https://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb [signed-by=$KEYRING] https://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb [signed-by=$KEYRING] https://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
APT_OPTS=(
    -o APT::Architecture=arm64 -o "APT::Architectures::=arm64"
    -o "Dir::State::status=$ROOTFS/var/lib/dpkg/status"   # resolve against the image, not this machine
    -o "Dir::State::Lists=$APT/lists" -o "Dir::Cache=$APT" -o "Dir::Cache::archives=$APT/archives"
    -o "Dir::Etc::SourceList=$APT/sources.list" -o "Dir::Etc::SourceParts=$APT/empty"
    -o "Dir::Etc::Preferences=$APT/empty/none" -o "Dir::Etc::PreferencesParts=$APT/empty"
    -o APT::Sandbox::User=root
)
[[ -n ${https_proxy:-${HTTPS_PROXY:-}} ]] && APT_OPTS+=(-o "Acquire::https::Proxy=${https_proxy:-$HTTPS_PROXY}")
[[ -n ${APT_CA:-} ]] && APT_OPTS+=(-o "Acquire::https::CaInfo=$APT_CA")
apt-get "${APT_OPTS[@]}" -qq update
mapfile -t PKGS < <(grep -v '^#' "$HERE/packages.txt" | grep .)
apt-get "${APT_OPTS[@]}" -y -qq --download-only --no-install-recommends install "${PKGS[@]}"
cp "$APT"/archives/*.deb "$PAYLOAD/debs/"
log "$(find "$PAYLOAD/debs" -name '*.deb' | wc -l) packages, $(du -sh "$PAYLOAD/debs" | cut -f1)"

log "fetching the pinned sources"
grep -v '^#' "$HERE/sources.lock" | while read -r name repo commit; do
    [[ -n $name ]] || continue
    g=$WORK/git/$name
    [[ -d $g ]] || git init -q "$g"
    git -C "$g" fetch -q --depth 1 "$repo" "$commit"
    git -C "$g" archive --prefix="$name/" -o "$PAYLOAD/src/$name.tar.gz" "$commit"
    log "  $name @ ${commit:0:12}"
done

# ---------------------------------------------------------------- new root
log "writing the root filesystem (mkfs.btrfs --rootdir, ${ROOT_MB} MB)"
truncate -s "${ROOT_MB}M" "$WORK/root.btrfs"
mkfs.btrfs -q -f -L "$LABEL" -U "$FSID" --rootdir "$ROOTFS" "$WORK/root.btrfs"
btrfs check --readonly "$WORK/root.btrfs" > "$WORK/check.log" 2>&1 \
    || { cat "$WORK/check.log"; echo "btrfs check failed"; exit 1; }

# ---------------------------------------------------------------- assemble
log "assembling the image"
IMG=$OUT/$NAME.img
dd if="$WORK/base.img" of="$IMG" bs=512 count="$P2_START" status=none       # MBR, u-boot, FAT
cat "$WORK/root.btrfs" >> "$IMG"
sfdisk -q --no-reread --no-tell-kernel -N 2 "$IMG" <<< "$P2_START,$((ROOT_MB * 2048))"
mcopy -o -i "$IMG@@$((P1_START * 512))" "$HERE/boot/adsb-station.conf" ::/adsb-station.conf
rm -f "$WORK/base.img" "$WORK/root.btrfs"

log "compressing"
xz -T0 -6 -f "$IMG"
(cd "$OUT" && sha256sum "$NAME.img.xz" > "$NAME.img.xz.sha256")
log "done: $IMG.xz ($(du -h "$IMG.xz" | cut -f1))"
echo "rootfs tree kept in $ROOTFS for inspection; remove it before the next run"
