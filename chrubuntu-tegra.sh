#!/bin/bash
# chrubuntu-tegra.sh - install Ubuntu on a Tegra Chromebook
# (HP Chromebook 14 G3 / nyan, Acer Chromebook 13 / nyan_blaze, ...)
#
# usage: sudo bash chrubuntu-tegra.sh [metapackage] [version] [device]
#   metapackage  default | ubuntu-desktop | xubuntu-desktop | ubuntu-minimal ...
#   version      latest | lts | dev | 22.04 | 24.04 | 26.04 ...
#   device       optional medium to install to, e.g. /dev/mmcblk1 (SD card or
#                USB stick). Omit it to install next to ChromeOS.
#
# examples:
#   sudo bash chrubuntu-tegra.sh default latest /dev/mmcblk1
#   sudo bash chrubuntu-tegra.sh xubuntu-desktop lts
#
# environment switches:
#   NO_L4T=1       skip the NVIDIA L4T GPU blobs (software rendering instead)
#   L4T_URL=...    use a different NVIDIA L4T package URL
#   NO_BROWSER=1   install no web browser
#   ZRAM=0         do not set up zram swap
#   FORCE=1        skip the confirmation prompts

set -e

# ChromeOS no longer ships wget; curl is part of every build. This keeps the
# script working on both old and current ChromeOS without extra packages.
have() { command -v "$1" >/dev/null 2>&1; }

# cgpt/crossystem/rootdev/vbutil_kernel moved between ChromeOS releases.
if [ -d /usr/bin/old_bins ]; then
  PATH="/usr/bin/old_bins:$PATH"
  export PATH
fi

for tool in cgpt crossystem rootdev; do
  if ! have "$tool"; then
    echo "ERROR: '$tool' not found. Run this from a ChromeOS dev-mode shell" >&2
    echo "       (not from inside an installed Ubuntu)." >&2
    exit 1
  fi
done

if have curl; then
  NETCTL=curl
elif have wget; then
  NETCTL=wget
elif have python3; then
  NETCTL=python
else
  echo "ERROR: need curl to download Ubuntu, but it is not available." >&2
  exit 1
fi

http_get() {
  # http_get URL - prints the body to stdout
  case "$NETCTL" in
    curl)   curl -fsSL --retry 3 --retry-delay 2 --max-time 300 "$1" ;;
    wget)   wget -q -O - "$1" ;;
    python) python3 - "$1" <<'PY'
import sys, urllib.request
print(urllib.request.urlopen(sys.argv[1], timeout=300).read().decode('utf-8', 'replace'), end='')
PY
  esac
}

http_size() {
  # http_size URL - prints Content-Length when the server sends one
  case "$NETCTL" in
    curl) curl -fsSLI --max-time 30 "$1" 2>/dev/null | tr -d '\r' \
            | awk 'BEGIN{IGNORECASE=1}/^content-length:/{print $2}' | tail -1 ;;
    wget) wget --spider -S -O /dev/null "$1" 2>&1 | tr -d '\r' \
            | awk 'BEGIN{IGNORECASE=1}/Content-Length:/{print $2}' | tail -1 ;;
    python) python3 - "$1" <<'PY'
import sys, urllib.request
try:
    req = urllib.request.Request(sys.argv[1], method='HEAD')
    print(urllib.request.urlopen(req, timeout=60).headers.get('Content-Length', ''))
except Exception:
    pass
PY
  esac
}

fetch_to() {
  # fetch_to URL DEST - downloads a file, retrying on network errors
  echo "  downloading $(basename "$2") ..."
  case "$NETCTL" in
    curl)   curl -fSL --retry 3 --retry-delay 3 --max-time 900 -o "$2" "$1" ;;
    wget)   wget -q --tries=3 -O "$2" "$1" ;;
    python) python3 - "$1" "$2" <<'PY'
import shutil, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=900) as r, open(sys.argv[2], 'wb') as f:
    shutil.copyfileobj(r, f)
PY
  esac
}

ask_continue() {
  if [ "$FORCE" = "1" ]; then
    return 0
  fi
  read -p "$1" _
}

# fw_type is 'developer' in dev mode. Old devices also need the developer
# firmware (chromeos-firmwareupdate --mode=todev) before a custom kernel boots.
fw_type="`crossystem mainfw_type 2>/dev/null || true`"
dev_switch="`crossystem devsw_boot 2>/dev/null || true`"
if [ ! "$fw_type" = "developer" ] && [ "$dev_switch" != "1" ] && [ "$FORCE" != "1" ]
  then
    echo -e "\nYour Chromebook is not in developer mode!"
    echo -e "You need to run:"
    echo -e ""
    echo -e "sudo chromeos-firmwareupdate --mode=todev"
    echo -e "sudo crossystem dev_boot_signed_only=0 dev_boot_usb=1"
    echo -e ""
    echo -e "and then re-run this script (FORCE=1 skips this check)."
    exit 1
fi

# powerd blanks the screen while the install runs.
if have stop; then
  stop powerd >/dev/null 2>&1 || true
elif have initctl && initctl status powerd >/dev/null 2>&1; then
  initctl stop powerd >/dev/null 2>&1 || true
fi

setterm -blank 0 2>/dev/null || true

if [ "$3" != "" ]; then
  target_disk=$3
  if [ ! -b "$target_disk" ]
  then
    echo "ERROR: $target_disk is not a block device. Check the name with lsblk." >&2
    exit 1
  fi
  echo "Got ${target_disk} as target drive"
  echo ""
  echo "WARNING! All data on this device will be wiped out! Continue at your own risk!"
  echo ""
  ask_continue "Press [Enter] to install ChrUbuntu on ${target_disk} or CTRL+C to quit"

  # blockdev is not in every ChromeOS build; cgpt can report the size too.
  ext_size="`blockdev --getsz "$target_disk" 2>/dev/null || cgpt show -s -q "$target_disk"`"
  if [ -z "$ext_size" ]; then
    echo "ERROR: could not read the size of ${target_disk}." >&2
    exit 1
  fi
  aroot_size=$((ext_size - 65600 - 33 - 4*1024*1024*1024/512))
  if [ "$aroot_size" -le 0 ]; then
    echo "ERROR: ${target_disk} is too small; use at least a 8 GB card." >&2
    exit 1
  fi
  # parted and partprobe are gone from ChromeOS; cgpt creates the GPT itself,
  # so a pre-formatted card is no longer required.
  cgpt create ${target_disk} || true
  # 32 and 16 GB disks work above but not 4 GB
  cgpt add -i 6 -b 64 -s 32768 -S 1 -P 5 -l KERN-A -t "kernel" ${target_disk}
  cgpt add -i 7 -b 65600 -s $aroot_size -l ROOT-A -t "rootfs" ${target_disk}
  sync
  blockdev --rereadpt ${target_disk} 2>/dev/null || true
  crossystem dev_boot_usb=1 || true
else
  target_disk="`rootdev -d -s`"
  # Do partitioning (if we haven't already)
  ckern_size="`cgpt show -i 6 -n -s -q ${target_disk}`"
  croot_size="`cgpt show -i 7 -n -s -q ${target_disk}`"
  state_size="`cgpt show -i 1 -n -s -q ${target_disk}`"

  max_ubuntu_size=$(($state_size/1024/1024/2))
  rec_ubuntu_size=$(($max_ubuntu_size - 1))
  # If KERN-C and ROOT-C are one, we partition, otherwise assume they're what they need to be...
  if [ "$ckern_size" = "1" ] || [ "$croot_size" = "1" ]
  then
    while :
    do
      read -p "Enter the size in gigabytes you want to reserve for Ubuntu. Acceptable range is 5 to $max_ubuntu_size  but $rec_ubuntu_size is the recommended maximum: " ubuntu_size
      case "$ubuntu_size" in
        ''|*[!0-9]*)
          echo -e "\n\nNumbers only please...\n\n"
          continue
          ;;
      esac
      if [ "$ubuntu_size" -lt 5 ] || [ "$ubuntu_size" -gt "$max_ubuntu_size" ]
      then
        echo -e "\n\nThat number is out of range. Enter a number 5 through $max_ubuntu_size\n\n"
        continue
      fi
      break
    done
    # We've got our size in GB for ROOT-C so do the math...

    # Calculate sector size for rootc
    rootc_size=$(($ubuntu_size*1024*1024*2))

    # kernc is always 16mb
    kernc_size=32768

    # New stateful size with rootc and kernc subtracted from original
    stateful_size=$(($state_size - $rootc_size - $kernc_size))

    # Start stateful at the same spot it currently starts at
    stateful_start="`cgpt show -i 1 -n -b -q ${target_disk}`"

    # Start kernc at stateful start plus stateful size
    kernc_start=$(($stateful_start + $stateful_size))

    # Start rootc at kernc start plus kernc size
    rootc_start=$(($kernc_start + $kernc_size))

    # Do the real work

    echo -e "\n\nModifying partition table to make room for Ubuntu."
    echo -e "Your Chromebook will reboot, wipe your data and then"
    echo -e "you should re-run this script..."
    if ! umount -f /mnt/stateful_partition 2>/dev/null
    then
      echo "Could not unmount /mnt/stateful_partition; trying a lazy unmount."
      umount -l /mnt/stateful_partition 2>/dev/null || true
    fi
    if mount | grep -q "on /mnt/stateful_partition "
    then
      echo "ERROR: /mnt/stateful_partition is still mounted. Reboot and re-run." >&2
      exit 1
    fi

    # stateful first
    cgpt add -i 1 -b $stateful_start -s $stateful_size -l STATE ${target_disk}

    # now kernc
    cgpt add -i 6 -b $kernc_start -s $kernc_size -l KERN-C ${target_disk}

    # finally rootc
    cgpt add -i 7 -b $rootc_start -s $rootc_size -l ROOT-C ${target_disk}

    reboot
    exit
  fi
fi

# hwid identifies the model (an HP Chromebook 14 G3 reports nyan_blaze).
hwid="`crossystem hwid 2>/dev/null || echo unknown`"
board="`crossystem board 2>/dev/null || echo unknown`"

chromebook_arch="`uname -m`"

ubuntu_metapackage=${1:-default}

META_RELEASE="https://changelogs.ubuntu.com/meta-release"
META_DEV="https://changelogs.ubuntu.com/meta-release-development"

echo "Reading the Ubuntu release list from changelogs.ubuntu.com ..."
meta="`http_get "$META_RELEASE"`"
latest_ubuntu="`echo "$meta" | awk '/^Version:/{v=$2} END{print v}'`"
latest_lts="`echo "$meta" | awk '/^Version:/ && /LTS/{v=$2} END{print v}'`"

ubuntu_version=${2:-$latest_ubuntu}
ubuntu_dist=""

case "$ubuntu_version" in
  latest)
    ubuntu_version=$latest_ubuntu
    ;;
  lts)
    ubuntu_version=$latest_lts
    ;;
  dev)
    # The old ubuntu-core daily images are gone; dev releases are published
    # under their codename in the normal ubuntu-base tree now.
    ubuntu_dist="`http_get "$META_DEV" | awk '/^Dist:/{d=$2} END{print d}'`"
    ubuntu_version=$ubuntu_dist
    ;;
esac

if [ -z "$ubuntu_version" ]; then
  echo "ERROR: could not read the Ubuntu release list from $META_RELEASE" >&2
  echo "       (check the network connection and try again)." >&2
  exit 1
fi

if [ "$chromebook_arch" = "x86_64" ]
then
  ubuntu_arch="amd64"
  if [ "$ubuntu_metapackage" = "default" ]
  then
    ubuntu_metapackage="ubuntu-desktop"
  fi
elif [ "$chromebook_arch" = "i686" ]
then
  ubuntu_arch="i386"
  if [ "$ubuntu_metapackage" = "default" ]
  then
    ubuntu_metapackage="ubuntu-desktop"
  fi
elif [ "$chromebook_arch" = "armv7l" ] || [ "$chromebook_arch" = "armv8l" ]
then
  ubuntu_arch="armhf"
  if [ "$ubuntu_metapackage" = "default" ]
  then
    ubuntu_metapackage="xubuntu-desktop"
  fi
elif [ "$chromebook_arch" = "aarch64" ]
then
  ubuntu_arch="arm64"
  if [ "$ubuntu_metapackage" = "default" ]
  then
    ubuntu_metapackage="xubuntu-desktop"
  fi
else
  echo -e "Error: This script doesn't know how to install ChrUbuntu on $chromebook_arch"
  exit 1
fi

# The ubuntu-base tarballs are built per point release (22.04.5, 26.04.1...),
# so ask cdimage which file actually exists instead of guessing one name.
ubuntu_base_url() {
  local index pick
  index="`http_get "https://cdimage.ubuntu.com/ubuntu-base/releases/$1/release/" 2>/dev/null || true`"
  pick="`echo "$index" | grep -o "ubuntu-base-[0-9][0-9.]*-base-$2\.tar\.gz" | sort -u -V | tail -1 || true`"
  [ -n "$pick" ] || return 1
  echo "https://cdimage.ubuntu.com/ubuntu-base/releases/$1/release/$pick"
}

echo "Resolving the Ubuntu base tarball for ${ubuntu_version}/${ubuntu_arch} ..."
tar_file="`ubuntu_base_url "$ubuntu_version" "$ubuntu_arch" || true`"
if [ -z "$tar_file" ] && echo "$ubuntu_version" | grep -q '^[0-9][0-9]*\.[0-9][0-9]*\.'
then
  # A point release (22.04.5) with no directory of its own still lives in the
  # directory of its series (22.04).
  ubuntu_series="${ubuntu_version%.*}"
  tar_file="`ubuntu_base_url "$ubuntu_series" "$ubuntu_arch" || true`"
fi
if [ -z "$tar_file" ]; then
  echo "" >&2
  echo "ERROR: no ubuntu-base image for Ubuntu ${ubuntu_version} on ${ubuntu_arch}." >&2
  echo "       armhf stopped getting desktop images after 22.04, so on this" >&2
  echo "       machine (${board}) try: sudo bash $0 ${ubuntu_metapackage} 22.04" >&2
  exit 1
fi
tar_size="`http_size "$tar_file" || true`"
if [ -n "$tar_size" ]; then
  tar_size="$((tar_size / 1024 / 1024)) MB"
fi

echo -e "\nChrome device model is: $hwid (board: $board)\n"

echo -e "Installing Ubuntu ${ubuntu_version} with metapackage ${ubuntu_metapackage}\n"

echo -e "Kernel Arch is: $chromebook_arch \n"
echo -e "Installing Ubuntu Arch: $ubuntu_arch\n"
echo -e "Base image: ${tar_file}${tar_size:+ (${tar_size})}\n"

ask_continue "Press [Enter] to continue..."

if [ ! -d /mnt/stateful_partition/ubuntu ]
then
  mkdir /mnt/stateful_partition/ubuntu
fi

cd /mnt/stateful_partition/ubuntu

if [[ "${target_disk}" =~ "mmcblk" ]]
then
  target_rootfs="${target_disk}p7"
  target_kern="${target_disk}p6"
else
  target_rootfs="${target_disk}7"
  target_kern="${target_disk}6"
fi

echo "Target Kernel Partition: $target_kern  Target Root FS: ${target_rootfs}"

if ! [ -b "$target_rootfs" ]
then
  echo "Refusing to continue: ${target_rootfs} does not exist." >&2
  echo "Check that the card is inserted and that ${target_disk} is the right disk" >&2
  echo "(lsblk lists them; partitions are ${target_disk}7 or ${target_disk}p7)." >&2
  exit 1
fi

is_mounted() {
  # mount output is "<dev> on <dir> type <fs> (...)"; match the whole field so
  # /tmp/urfs does not also match /tmp/urfs/sys.
  mount | grep -q " on $1 "
}

target_mounted() {
  mount | grep -q "^${target_rootfs} on "
}

free_target_rootfs() {
  # A previous run can leave the target mounted: an older version of this
  # script died after mounting /tmp/urfs (it needed wget to download), and
  # nothing ever unmounted it. A leftover mount is not a reason to abort, it
  # only has to be released before mkfs and a fresh mount.
  local line mp m
  target_mounted || return 0

  line="`mount | grep "^${target_rootfs} on " | head -1`"
  echo ""
  echo "WARNING: ${target_rootfs} is already mounted:"
  echo "  $line"
  mp="`echo "$line" | sed -n 's/^[^ ]* on \\(.*\\) type .*/\\1/p'`"
  echo "Unmounting it so the install can continue ..."

  for m in "$mp" /tmp/urfs "$target_rootfs"
  do
    [ -n "$m" ] || continue
    if target_mounted; then
      umount "$m" 2>/dev/null || true
    fi
  done

  # Last resort: a lazy unmount detaches the mount even when a stale chroot
  # process still holds a file open.
  if target_mounted
  then
    for m in "$mp" /tmp/urfs
    do
      [ -n "$m" ] || continue
      umount -l "$m" 2>/dev/null || true
    done
    sleep 1
  fi

  if target_mounted
  then
    echo "" >&2
    echo "ERROR: ${target_rootfs} is mounted and could not be unmounted" >&2
    echo "       automatically. Free it by hand and re-run this script:" >&2
    echo "" >&2
    echo "         sudo umount /tmp/urfs" >&2
    echo "         sudo umount ${target_rootfs}" >&2
    echo "" >&2
    echo "       If it still says the target is busy, reboot the Chromebook" >&2
    echo "       (Ctrl-Alt-T, type 'shell', then 'sudo reboot') and start over." >&2
    echo "       Do not run mkfs on a mounted partition; that corrupts it." >&2
    exit 1
  fi
  echo "Unmounted ${target_rootfs}; continuing."
  echo ""
}

cleanup_chroot() {
  # Runs on every exit path, including a failed install, so the next run never
  # starts with the target partition still mounted.
  local m
  for m in sys dev/pts dev proc
  do
    if is_mounted "/tmp/urfs/$m"; then
      umount "/tmp/urfs/$m" 2>/dev/null || true
    fi
  done
  if is_mounted /tmp/urfs; then
    umount /tmp/urfs 2>/dev/null || umount -l /tmp/urfs 2>/dev/null || true
  fi
  return 0
}

trap cleanup_chroot EXIT

free_target_rootfs

mkfs.ext4 -F ${target_rootfs}

if [ ! -d /tmp/urfs ]
then
  mkdir /tmp/urfs
fi
if ! mount -t ext4 ${target_rootfs} /tmp/urfs
then
  echo "ERROR: could not mount ${target_rootfs} on /tmp/urfs." >&2
  echo "       Run 'sudo e2fsck -f ${target_rootfs}' if mkfs complained above." >&2
  exit 1
fi

echo "Downloading the Ubuntu base image ..."
tarball="`mktemp`"
fetch_to "$tar_file" "$tarball"
if [ ! -s "$tarball" ]; then
  echo "ERROR: the download of $tar_file produced no data." >&2
  exit 1
fi
echo "Extracting the base image (this takes a while) ..."
tar xzvvp -f "$tarball" -C /tmp/urfs/
rm -f "$tarball"

mount -o bind /proc /tmp/urfs/proc
mount -o bind /dev /tmp/urfs/dev
mount -o bind /dev/pts /tmp/urfs/dev/pts
mount -o bind /sys /tmp/urfs/sys

cgpt_bin="`command -v cgpt || true`"
if [ -n "$cgpt_bin" ]
then
  cp "$cgpt_bin" /tmp/urfs/usr/bin/cgpt
  chmod a+rx /tmp/urfs/usr/bin/cgpt
else
  echo "WARNING: cgpt not found; the installed Ubuntu will not be able to" >&2
  echo "         switch its boot partition by itself." >&2
fi
# DNS inside the chroot. ChromeOS points /etc/resolv.conf at a runtime path,
# so copy the resolved file (or write public resolvers when there is none).
rm -f /tmp/urfs/etc/resolv.conf
if ! cp -L /etc/resolv.conf /tmp/urfs/etc/resolv.conf 2>/dev/null || [ ! -s /tmp/urfs/etc/resolv.conf ]
then
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /tmp/urfs/etc/resolv.conf
fi
mkdir -p /tmp/urfs/run/resolvconf
cp /tmp/urfs/etc/resolv.conf /tmp/urfs/run/resolvconf/resolv.conf
echo chrubuntu > /tmp/urfs/etc/hostname
#echo -e "127.0.0.1       localhost
echo -e "\n127.0.1.1       chrubuntu" >> /tmp/urfs/etc/hosts
# The following lines are desirable for IPv6 capable hosts
#::1     localhost ip6-localhost ip6-loopback
#fe00::0 ip6-localnet
#ff00::0 ip6-mcastprefix
#ff02::1 ip6-allnodes
#ff02::2 ip6-allrouters" > /tmp/urfs/etc/hosts

# Google Chrome dropped the apt-key shortcut; keys now go into a keyring file.
cr_install='install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
apt-get -y update
apt-get -y install google-chrome-stable'

if [ "$ubuntu_arch" != "amd64" ]
then
  # There is no armhf Google Chrome, and Ubuntu's chromium package is a snap
  # wrapper that cannot run inside a chroot, so use GNOME Web (epiphany).
  cr_install='apt-get -y install epiphany-browser || apt-get -y install chromium-browser || true'
fi

if [ "$NO_BROWSER" = "1" ]
then
  cr_install=""
fi

echo -e "export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y install ca-certificates curl gnupg locales
mkdir -p /etc/init.d
[ -e /etc/init.d/whoopsie ] || touch /etc/init.d/whoopsie
apt-get -y dist-upgrade
apt-get -y install ubuntu-minimal
apt-get -y install software-properties-common
add-apt-repository -y universe
add-apt-repository -y restricted
add-apt-repository -y multiverse
apt-get -y update
apt-get -y install $ubuntu_metapackage || apt-get -y install ubuntu-minimal
$cr_install
if [ '$ZRAM' != '0' ]; then apt-get -y install zram-tools || true; fi
if [ -f /usr/lib/lightdm/lightdm-set-defaults ]
then
  /usr/lib/lightdm/lightdm-set-defaults --autologin user
fi
useradd -m -s /bin/bash user
echo 'user:user' | chpasswd
adduser -q user adm 2>/dev/null || true
adduser -q user sudo 2>/dev/null || true
adduser -q user video 2>/dev/null || true
adduser -q user audio 2>/dev/null || true
adduser -q user plugdev 2>/dev/null || true
adduser -q user netdev 2>/dev/null || true
adduser -q user render 2>/dev/null || true
if [ -x /usr/bin/epiphany-browser ]; then
  update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/epiphany-browser 40 || true
elif [ -x /usr/bin/google-chrome-stable ]; then
  update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/google-chrome-stable 40 || true
fi
locale-gen en_US en_US.UTF-8
echo 'LANG=en_US.UTF-8' > /etc/default/locale
echo 'LC_ALL=en_US.UTF-8' >> /etc/default/locale
dpkg-reconfigure -f noninteractive locales" > /tmp/urfs/install-ubuntu.sh

chmod a+x /tmp/urfs/install-ubuntu.sh
chroot /tmp/urfs /bin/bash /install-ubuntu.sh
rm /tmp/urfs/install-ubuntu.sh

KERN_VER="`uname -r`"
mkdir -p /tmp/urfs/lib/modules/$KERN_VER/
if [ -d /lib/modules/$KERN_VER ]
then
  cp -ar /lib/modules/$KERN_VER/* /tmp/urfs/lib/modules/$KERN_VER/
else
  echo "WARNING: no kernel modules for $KERN_VER on this ChromeOS build." >&2
fi
mkdir -p /tmp/urfs/lib/firmware
if [ -d /lib/firmware ]
then
  cp -ar /lib/firmware/* /tmp/urfs/lib/firmware/ || true
fi

# The Adobe Flash plugin ChromeOS used to ship is gone, so nothing is copied
# here any more; browsers now need no PPAPI plugin.


# from https://chromium.googlesource.com/chromiumos/platform/xorg-conf/+/factory-4128.B/tegra.conf
mkdir -p /tmp/urfs/usr/share/X11/xorg.conf.d
cat > /tmp/urfs/usr/share/X11/xorg.conf.d/tegra.conf << EOF
Section "Module"
    Load        "glx"
EndSection
Section "Device"
    Identifier  "Tegra"
    Driver      "nvidia"
    Option      "ConstrainCursor" "false"
    Option      "NoLogo" "true"
# OverlayDepth is a 32-bit integer which is used to control overlay
# stacking order.  The overlay with the lowest depth is in front of
# all others.  This value has meaning only when multiple overlays are
# present on a display. This value can range between 0 & 255 (both values
# inclusive). The default being 255.
#    Option      "OverlayDepth" "0"
# OverlayCombineMode determines how the X overlay is combined with the
# overlay behind it during scanout.  Available modes are: Opaque
# (default), SourceAlphaBlend, and PremultSourceAlphaBlend.  This
# value has meaning only when an external process has created a
# display which is behind the X server.
#    Option      "OverlayCombineMode" "PremultSourceAlphaBlend"
# ARGBHWCursor controls whether the X driver uses an overlay to
# display 32-bit "true-color" cursors, or whether such cursors are
# emulated in software.  Valid values are "true" to enable hardware
# cursors, and "false" (default) to disable them.
    Option      "ARGBHWCursor" "true"
# Set the maximum number of pixmap caches used by the X driver.
# Valid values are 0 through 16 (default)
# A value of 0 disables the use of the caches for pixmaps.
# To use less memory, but still retain performance, the recommendation
# is to use one pixmap heap, set a small size, and limit the size
# of the surfaces that utilizes the pixmap cache.
#    Option      "PixmapCacheMaxHeaps"  "1"
# Set the size of each pixmap cache, in bytes.
# Valid values are 64 KiB though 64 MiB. Up to
# "PixmapCacheMaxHeaps" (see above) will be allocated
# if necessary. The default value is 8 MiB.
#    Option      "PixmapCacheSize"  "65536"
# Set the maximum size for a surface that uses
# the pixmap cache. If a surface exceeds this size
# it will be allocated as a separate allocation, outside
# the pixmap cache.
# The default value is the same as "PixmapCacheSize"
#    Option      "PixmapCacheMaxSurfaceSize"  "4096"
# Use monitor section with identifier LVDS for output named LVDS-1
#    Option      "monitor-LVDS-1" "LVDS"
#    Option      "monitor-HDMI-1" "HDMI"
EndSection
Section "ServerFlags"
    Option     "NoTrapSignals" "true"
    Option     "DontZap" "false"
    # Disable DPMS timeouts.
    Option     "StandbyTime" "0"
    Option     "SuspendTime" "0"
    Option     "OffTime" "0"
    # Disable screen saver timeout.
    Option     "BlankTime" "0"
EndSection
EOF

# NVIDIA L4T (Tegra K1) X/GL blobs. The tarball still resolves on NVIDIA's
# download host, but it is optional: a failed download must not kill the
# install, it only leaves the desktop on software rendering.
L4T_URL=${L4T_URL:-https://developer.download.nvidia.com/mobile/tegra/l4t/r21.1.0/Tegra124_Linux_R21.1.0_armhf.tbz2}
l4t_ok=0

if [ "$NO_L4T" = "1" ]
then
  echo "NO_L4T=1 is set - skipping the NVIDIA GPU blobs."
elif [ "$ubuntu_arch" != "armhf" ]
then
  echo "Skipping the NVIDIA L4T blobs (they are armhf only)."
else
  echo "Fetching the NVIDIA L4T GPU blobs ..."
  l4tdir="`mktemp -d`"
  l4t="`basename "$L4T_URL"`"
  if fetch_to "$L4T_URL" "$l4tdir/$l4t"
  then
    if tar xpf "$l4tdir/$l4t" -C "$l4tdir" 2>/dev/null && [ -d "$l4tdir/Linux_for_Tegra/rootfs" ]
    then
      if ( cd "$l4tdir/Linux_for_Tegra/rootfs" \
           && tar xpf ../nv_tegra/nvidia_drivers.tbz2 \
           && tar cf - usr/lib | ( cd /tmp/urfs ; tar xf - ) )
      then
        l4t_ok=1
      fi
    fi
  fi
  rm -rf "$l4tdir"
  if [ "$l4t_ok" != "1" ]
  then
    echo "WARNING: the NVIDIA L4T blobs could not be installed;" >&2
    echo "         the desktop will fall back to software rendering." >&2
  fi
fi

if [ "$l4t_ok" = "1" ]
then
  # cuda symlinks
  ln -sf libcuda.so.1 /tmp/urfs/usr/lib/arm-linux-gnueabihf/libcuda.so
  ln -sf tegra/libcuda.so.1 /tmp/urfs/usr/lib/arm-linux-gnueabihf/libcuda.so.1
  ln -sf tegra/libcuda.so.1.1 /tmp/urfs/usr/lib/arm-linux-gnueabihf/libcuda.so.1.1

  mkdir -p /tmp/urfs/etc/ld.so.conf.d
  echo "/usr/lib/arm-linux-gnueabihf/tegra" > /tmp/urfs/etc/ld.so.conf.d/nvidia-tegra.conf
  mkdir -p /tmp/urfs/usr/lib/arm-linux-gnueabihf/tegra-egl /tmp/urfs/usr/lib/arm-linux-gnueabihf/tegra
  echo "/usr/lib/arm-linux-gnueabihf/tegra-egl" > /tmp/urfs/usr/lib/arm-linux-gnueabihf/tegra-egl/ld.so.conf
  echo "/usr/lib/arm-linux-gnueabihf/tegra" > /tmp/urfs/usr/lib/arm-linux-gnueabihf/tegra/ld.so.conf
else
  # No NVIDIA driver means the tegra X config would point at a missing driver.
  rm -f /tmp/urfs/usr/share/X11/xorg.conf.d/tegra.conf
fi

mkdir -p /tmp/urfs/etc/udev/rules.d /tmp/urfs/lib/udev/rules.d /tmp/urfs/var/lib/alsa

cat >/tmp/urfs/etc/udev/rules.d/99-tegra-lid-switch.rules <<EOF
ACTION=="remove", GOTO="tegra_lid_switch_end"

SUBSYSTEM=="input", KERNEL=="event*", SUBSYSTEMS=="platform", KERNELS=="gpio-keys.4", TAG+="power-switch"

LABEL="tegra_lid_switch_end"
EOF

# nvidia device node permissions
cat > /tmp/urfs/lib/udev/rules.d/51-nvrm.rules <<EOF
KERNEL=="knvmap", GROUP="video", MODE="0660"
KERNEL=="nvhdcp1", GROUP="video", MODE="0660"
KERNEL=="nvhost-as-gpu", GROUP="video", MODE="0660"
KERNEL=="nvhost-ctrl", GROUP="video", MODE="0660"
KERNEL=="nvhost-ctrl-gpu", GROUP="video", MODE="0660"
KERNEL=="nvhost-dbg-gpu", GROUP="video", MODE="0660"
KERNEL=="nvhost-gpu", GROUP="video", MODE="0660"
KERNEL=="nvhost-msenc", GROUP="video", MODE="0660"
KERNEL=="nvhost-prof-gpu", GROUP="video", MODE="0660"
KERNEL=="nvhost-tsec", GROUP="video", MODE="0660"
KERNEL=="nvhost-vic", GROUP="video", MODE="0660"
KERNEL=="nvmap", GROUP="video", MODE="0660"
KERNEL=="tegra_dc_0", GROUP="video", MODE="0660"
KERNEL=="tegra_dc_1", GROUP="video", MODE="0660"
KERNEL=="tegra_dc_ctrl", GROUP="video", MODE="0660"
EOF

# alsa mixer settings to enable internal speakers
cat > /tmp/urfs/var/lib/alsa/asound.state <<EOF
state.HDATegra {
	control.1 {
		iface CARD
		name 'HDMI/DP,pcm=3 Jack'
		value false
		comment {
			access read
			type BOOLEAN
			count 1
		}
	}
	control.2 {
		iface MIXER
		name 'IEC958 Playback Con Mask'
		value '0fff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'
		comment {
			access read
			type IEC958
			count 1
		}
	}
	control.3 {
		iface MIXER
		name 'IEC958 Playback Pro Mask'
		value '0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'
		comment {
			access read
			type IEC958
			count 1
		}
	}
	control.4 {
		iface MIXER
		name 'IEC958 Playback Default'
		value '0400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'
		comment {
			access 'read write'
			type IEC958
			count 1
		}
	}
	control.5 {
		iface MIXER
		name 'IEC958 Playback Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.6 {
		iface PCM
		device 3
		name ELD
		value ''
		comment {
			access 'read volatile'
			type BYTES
			count 0
		}
	}
	control.7 {
		iface PCM
		device 3
		name 'Playback Channel Map'
		value.0 0
		value.1 0
		value.2 0
		value.3 0
		value.4 0
		value.5 0
		value.6 0
		value.7 0
		comment {
			access 'read write'
			type INTEGER
			count 8
			range '0 - 36'
		}
	}
}
state.Venice2 {
	control.1 {
		iface MIXER
		name 'MIC Bias VCM Bandgap'
		value 'High Performance'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 'Low Power'
			item.1 'High Performance'
		}
	}
	control.2 {
		iface MIXER
		name 'DMIC MIC Comp Filter Config'
		value 6
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 15'
		}
	}
	control.3 {
		iface MIXER
		name 'MIC1 Boost Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 2'
			dbmin 0
			dbmax 3000
			dbvalue.0 0
		}
	}
	control.4 {
		iface MIXER
		name 'MIC2 Boost Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 2'
			dbmin 0
			dbmax 3000
			dbvalue.0 0
		}
	}
	control.5 {
		iface MIXER
		name 'MIC1 Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 20'
			dbmin 0
			dbmax 2000
			dbvalue.0 0
		}
	}
	control.6 {
		iface MIXER
		name 'MIC2 Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 20'
			dbmin 0
			dbmax 2000
			dbvalue.0 0
		}
	}
	control.7 {
		iface MIXER
		name 'LINEA Single Ended Volume'
		value 1
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 1'
			dbmin -600
			dbmax 0
			dbvalue.0 0
		}
	}
	control.8 {
		iface MIXER
		name 'LINEB Single Ended Volume'
		value 1
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 1'
			dbmin -600
			dbmax 0
			dbvalue.0 0
		}
	}
	control.9 {
		iface MIXER
		name 'LINEA Volume'
		value 2
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 5'
			dbmin -600
			dbmax 2000
			dbvalue.0 0
		}
	}
	control.10 {
		iface MIXER
		name 'LINEB Volume'
		value 2
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 5'
			dbmin -600
			dbmax 2000
			dbvalue.0 0
		}
	}
	control.11 {
		iface MIXER
		name 'LINEA Ext Resistor Gain Mode'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.12 {
		iface MIXER
		name 'LINEB Ext Resistor Gain Mode'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.13 {
		iface MIXER
		name 'ADCL Boost Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 7'
			dbmin 0
			dbmax 4200
			dbvalue.0 0
		}
	}
	control.14 {
		iface MIXER
		name 'ADCR Boost Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 7'
			dbmin 0
			dbmax 4200
			dbvalue.0 0
		}
	}
	control.15 {
		iface MIXER
		name 'ADCL Volume'
		value 12
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 15'
			dbmin -1200
			dbmax 300
			dbvalue.0 0
		}
	}
	control.16 {
		iface MIXER
		name 'ADCR Volume'
		value 12
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 15'
			dbmin -1200
			dbmax 300
			dbvalue.0 0
		}
	}
	control.17 {
		iface MIXER
		name 'ADC Oversampling Rate'
		value '128*fs'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 '64*fs'
			item.1 '128*fs'
		}
	}
	control.18 {
		iface MIXER
		name 'ADC Quantizer Dither'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.19 {
		iface MIXER
		name 'ADC High Performance Mode'
		value 'High Performance'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 'Low Power'
			item.1 'High Performance'
		}
	}
	control.20 {
		iface MIXER
		name 'DAC Mono Mode'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.21 {
		iface MIXER
		name 'SDIN Mode'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.22 {
		iface MIXER
		name 'SDOUT Mode'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.23 {
		iface MIXER
		name 'SDOUT Hi-Z Mode'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.24 {
		iface MIXER
		name 'Filter Mode'
		value Music
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 Voice
			item.1 Music
		}
	}
	control.25 {
		iface MIXER
		name 'Record Path DC Blocking'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.26 {
		iface MIXER
		name 'Playback Path DC Blocking'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.27 {
		iface MIXER
		name 'Digital BQ Volume'
		value 15
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 15'
			dbmin -1500
			dbmax 0
			dbvalue.0 0
		}
	}
	control.28 {
		iface MIXER
		name 'Digital Sidetone Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 30'
			dbmin 0
			dbmax 3000
			dbvalue.0 0
		}
	}
	control.29 {
		iface MIXER
		name 'Digital Coarse Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 3'
			dbmin 0
			dbmax 1800
			dbvalue.0 0
		}
	}
	control.30 {
		iface MIXER
		name 'Digital Volume'
		value 15
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 15'
			dbmin -1500
			dbmax 0
			dbvalue.0 0
		}
	}
	control.31 {
		iface MIXER
		name 'EQ Coefficients'
		value '000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'
		comment {
			access 'read write'
			type BYTES
			count 105
		}
	}
	control.32 {
		iface MIXER
		name 'Digital EQ 3 Band Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.33 {
		iface MIXER
		name 'Digital EQ 5 Band Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.34 {
		iface MIXER
		name 'Digital EQ 7 Band Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.35 {
		iface MIXER
		name 'Digital EQ Clipping Detection'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.36 {
		iface MIXER
		name 'Digital EQ Volume'
		value 15
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 15'
			dbmin -1500
			dbmax 0
			dbvalue.0 0
		}
	}
	control.37 {
		iface MIXER
		name 'ALC Enable'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.38 {
		iface MIXER
		name 'ALC Attack Time'
		value '0.5ms'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 '0.5ms'
			item.1 '1ms'
			item.2 '5ms'
			item.3 '10ms'
			item.4 '25ms'
			item.5 '50ms'
			item.6 '100ms'
			item.7 '200ms'
		}
	}
	control.39 {
		iface MIXER
		name 'ALC Release Time'
		value '8s'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 '8s'
			item.1 '4s'
			item.2 '2s'
			item.3 '1s'
			item.4 '0.5s'
			item.5 '0.25s'
			item.6 '0.125s'
			item.7 '0.0625s'
		}
	}
	control.40 {
		iface MIXER
		name 'ALC Make Up Volume'
		value 0
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 12'
			dbmin 0
			dbmax 1200
			dbvalue.0 0
		}
	}
	control.41 {
		iface MIXER
		name 'ALC Compression Ratio'
		value '1:1'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 '1:1'
			item.1 '1:1.5'
			item.2 '1:2'
			item.3 '1:4'
			item.4 '1:INF'
		}
	}
	control.42 {
		iface MIXER
		name 'ALC Expansion Ratio'
		value '1:1'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 '1:1'
			item.1 '2:1'
			item.2 '3:1'
		}
	}
	control.43 {
		iface MIXER
		name 'ALC Compression Threshold Volume'
		value 31
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 31'
			dbmin -3100
			dbmax 0
			dbvalue.0 0
		}
	}
	control.44 {
		iface MIXER
		name 'ALC Expansion Threshold Volume'
		value 31
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 31'
			dbmin -6600
			dbmax -3500
			dbvalue.0 -3500
		}
	}
	control.45 {
		iface MIXER
		name 'DAC HP Playback Performance Mode'
		value 'High Performance'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 'High Performance'
			item.1 'Low Power'
		}
	}
	control.46 {
		iface MIXER
		name 'DAC High Performance Mode'
		value 'High Performance'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 'Low Power'
			item.1 'High Performance'
		}
	}
	control.47 {
		iface MIXER
		name 'Headphone Left Mixer Volume'
		value 3
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 3'
			dbmin -1200
			dbmax 0
			dbvalue.0 0
		}
	}
	control.48 {
		iface MIXER
		name 'Headphone Right Mixer Volume'
		value 3
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 3'
			dbmin -1200
			dbmax 0
			dbvalue.0 0
		}
	}
	control.49 {
		iface MIXER
		name 'Speaker Left Mixer Volume'
		value 3
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 3'
			dbmin -1200
			dbmax 0
			dbvalue.0 0
		}
	}
	control.50 {
		iface MIXER
		name 'Speaker Right Mixer Volume'
		value 3
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 3'
			dbmin -1200
			dbmax 0
			dbvalue.0 0
		}
	}
	control.51 {
		iface MIXER
		name 'Receiver Left Mixer Volume'
		value 3
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 3'
			dbmin -1200
			dbmax 0
			dbvalue.0 0
		}
	}
	control.52 {
		iface MIXER
		name 'Receiver Right Mixer Volume'
		value 3
		comment {
			access 'read write'
			type INTEGER
			count 1
			range '0 - 3'
			dbmin -1200
			dbmax 0
			dbvalue.0 0
		}
	}
	control.53 {
		iface MIXER
		name 'Headphone Volume'
		value.0 26
		value.1 26
		comment {
			access 'read write'
			type INTEGER
			count 2
			range '0 - 31'
			dbmin -6700
			dbmax 300
			dbvalue.0 0
			dbvalue.1 0
		}
	}
	control.54 {
		iface MIXER
		name 'Speaker Volume'
		value.0 20
		value.1 20
		comment {
			access 'read write'
			type INTEGER
			count 2
			range '0 - 39'
			dbmin -4800
			dbmax 1400
			dbvalue.0 0
			dbvalue.1 0
		}
	}
	control.55 {
		iface MIXER
		name 'Receiver Volume'
		value.0 21
		value.1 21
		comment {
			access 'read write'
			type INTEGER
			count 2
			range '0 - 31'
			dbmin -6200
			dbmax 800
			dbvalue.0 0
			dbvalue.1 0
		}
	}
	control.56 {
		iface MIXER
		name 'Headphone Left Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.57 {
		iface MIXER
		name 'Headphone Right Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.58 {
		iface MIXER
		name 'Speaker Left Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.59 {
		iface MIXER
		name 'Speaker Right Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.60 {
		iface MIXER
		name 'Receiver Left Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.61 {
		iface MIXER
		name 'Receiver Right Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.62 {
		iface MIXER
		name 'Zero-Crossing Detection'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.63 {
		iface MIXER
		name 'Enhanced Vol Smoothing'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.64 {
		iface MIXER
		name 'Volume Adjustment Smoothing'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.65 {
		iface MIXER
		name 'Biquad Coefficients'
		value '000000000000000000000000000000'
		comment {
			access 'read write'
			type BYTES
			count 15
		}
	}
	control.66 {
		iface MIXER
		name 'Biquad Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.67 {
		iface MIXER
		name 'HP Right Out Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.68 {
		iface MIXER
		name 'HP Left Out Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.69 {
		iface MIXER
		name 'MIXHPRSEL Mux'
		value 'DAC Only'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 'DAC Only'
			item.1 'HP Mixer'
		}
	}
	control.70 {
		iface MIXER
		name 'MIXHPLSEL Mux'
		value 'DAC Only'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 'DAC Only'
			item.1 'HP Mixer'
		}
	}
	control.71 {
		iface MIXER
		name 'LINMOD Mux'
		value 'Left Only'
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 'Left Only'
			item.1 'Left and Right'
		}
	}
	control.72 {
		iface MIXER
		name 'Right Receiver Mixer Left DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.73 {
		iface MIXER
		name 'Right Receiver Mixer Right DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.74 {
		iface MIXER
		name 'Right Receiver Mixer LINEA Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.75 {
		iface MIXER
		name 'Right Receiver Mixer LINEB Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.76 {
		iface MIXER
		name 'Right Receiver Mixer MIC1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.77 {
		iface MIXER
		name 'Right Receiver Mixer MIC2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.78 {
		iface MIXER
		name 'Left Receiver Mixer Left DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.79 {
		iface MIXER
		name 'Left Receiver Mixer Right DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.80 {
		iface MIXER
		name 'Left Receiver Mixer LINEA Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.81 {
		iface MIXER
		name 'Left Receiver Mixer LINEB Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.82 {
		iface MIXER
		name 'Left Receiver Mixer MIC1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.83 {
		iface MIXER
		name 'Left Receiver Mixer MIC2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.84 {
		iface MIXER
		name 'Right Speaker Mixer Left DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.85 {
		iface MIXER
		name 'Right Speaker Mixer Right DAC Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.86 {
		iface MIXER
		name 'Right Speaker Mixer LINEA Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.87 {
		iface MIXER
		name 'Right Speaker Mixer LINEB Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.88 {
		iface MIXER
		name 'Right Speaker Mixer MIC1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.89 {
		iface MIXER
		name 'Right Speaker Mixer MIC2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.90 {
		iface MIXER
		name 'Left Speaker Mixer Left DAC Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.91 {
		iface MIXER
		name 'Left Speaker Mixer Right DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.92 {
		iface MIXER
		name 'Left Speaker Mixer LINEA Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.93 {
		iface MIXER
		name 'Left Speaker Mixer LINEB Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.94 {
		iface MIXER
		name 'Left Speaker Mixer MIC1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.95 {
		iface MIXER
		name 'Left Speaker Mixer MIC2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.96 {
		iface MIXER
		name 'Right Headphone Mixer Left DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.97 {
		iface MIXER
		name 'Right Headphone Mixer Right DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.98 {
		iface MIXER
		name 'Right Headphone Mixer LINEA Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.99 {
		iface MIXER
		name 'Right Headphone Mixer LINEB Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.100 {
		iface MIXER
		name 'Right Headphone Mixer MIC1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.101 {
		iface MIXER
		name 'Right Headphone Mixer MIC2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.102 {
		iface MIXER
		name 'Left Headphone Mixer Left DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.103 {
		iface MIXER
		name 'Left Headphone Mixer Right DAC Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.104 {
		iface MIXER
		name 'Left Headphone Mixer LINEA Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.105 {
		iface MIXER
		name 'Left Headphone Mixer LINEB Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.106 {
		iface MIXER
		name 'Left Headphone Mixer MIC1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.107 {
		iface MIXER
		name 'Left Headphone Mixer MIC2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.108 {
		iface MIXER
		name 'STENR Mux'
		value Normal
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 Normal
			item.1 'Sidetone Right'
		}
	}
	control.109 {
		iface MIXER
		name 'STENL Mux'
		value Normal
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 Normal
			item.1 'Sidetone Left'
		}
	}
	control.110 {
		iface MIXER
		name 'LTENR Mux'
		value Normal
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 Normal
			item.1 Loopthrough
		}
	}
	control.111 {
		iface MIXER
		name 'LTENL Mux'
		value Normal
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 Normal
			item.1 Loopthrough
		}
	}
	control.112 {
		iface MIXER
		name 'LBENR Mux'
		value Normal
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 Normal
			item.1 Loopback
		}
	}
	control.113 {
		iface MIXER
		name 'LBENL Mux'
		value Normal
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 Normal
			item.1 Loopback
		}
	}
	control.114 {
		iface MIXER
		name 'Right ADC Mixer IN12 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.115 {
		iface MIXER
		name 'Right ADC Mixer IN34 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.116 {
		iface MIXER
		name 'Right ADC Mixer IN56 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.117 {
		iface MIXER
		name 'Right ADC Mixer LINEA Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.118 {
		iface MIXER
		name 'Right ADC Mixer LINEB Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.119 {
		iface MIXER
		name 'Right ADC Mixer MIC1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.120 {
		iface MIXER
		name 'Right ADC Mixer MIC2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.121 {
		iface MIXER
		name 'Left ADC Mixer IN12 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.122 {
		iface MIXER
		name 'Left ADC Mixer IN34 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.123 {
		iface MIXER
		name 'Left ADC Mixer IN56 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.124 {
		iface MIXER
		name 'Left ADC Mixer LINEA Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.125 {
		iface MIXER
		name 'Left ADC Mixer LINEB Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.126 {
		iface MIXER
		name 'Left ADC Mixer MIC1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.127 {
		iface MIXER
		name 'Left ADC Mixer MIC2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.128 {
		iface MIXER
		name 'LINEB Mixer IN2 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.129 {
		iface MIXER
		name 'LINEB Mixer IN4 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.130 {
		iface MIXER
		name 'LINEB Mixer IN6 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.131 {
		iface MIXER
		name 'LINEB Mixer IN56 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.132 {
		iface MIXER
		name 'LINEA Mixer IN1 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.133 {
		iface MIXER
		name 'LINEA Mixer IN3 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.134 {
		iface MIXER
		name 'LINEA Mixer IN5 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.135 {
		iface MIXER
		name 'LINEA Mixer IN34 Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.136 {
		iface MIXER
		name 'DMIC Mux'
		value ADC
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 ADC
			item.1 DMIC
		}
	}
	control.137 {
		iface MIXER
		name 'MIC2 Mux'
		value IN34
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 IN34
			item.1 IN56
		}
	}
	control.138 {
		iface MIXER
		name 'MIC1 Mux'
		value IN12
		comment {
			access 'read write'
			type ENUMERATED
			count 1
			item.0 IN12
			item.1 IN56
		}
	}
	control.139 {
		iface MIXER
		name 'Speakers Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.140 {
		iface MIXER
		name 'Headphone Jack Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.141 {
		iface MIXER
		name 'Mic Jack Switch'
		value false
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
	control.142 {
		iface MIXER
		name 'Int Mic Switch'
		value true
		comment {
			access 'read write'
			type BOOLEAN
			count 1
		}
	}
}
EOF

if [ "$l4t_ok" = "1" ]
then
  cat > /tmp/urfs/install-tegra.sh <<EOF
update-alternatives --install /etc/ld.so.conf.d/arm-linux-gnueabihf_EGL.conf arm-linux-gnueabihf_egl_conf /usr/lib/arm-linux-gnueabihf/tegra-egl/ld.so.conf 1000 || true
update-alternatives --install /etc/ld.so.conf.d/arm-linux-gnueabihf_GL.conf arm-linux-gnueabihf_gl_conf /usr/lib/arm-linux-gnueabihf/tegra/ld.so.conf 1000 || true
ldconfig
adduser -q user video 2>/dev/null || true
EOF

  chmod a+x /tmp/urfs/install-tegra.sh
  chroot /tmp/urfs /bin/bash /install-tegra.sh
  rm /tmp/urfs/install-tegra.sh
fi

echo "console=tty1 debug verbose root=${target_rootfs} rootwait rw lsm.module_locking=0" > kernel-config
vbutil_arch="x86"
if [ $ubuntu_arch = "armhf" ] || [ $ubuntu_arch = "arm64" ]
then
  vbutil_arch="arm"
fi

current_rootfs="`rootdev -s`"
current_kernfs_num=$((${current_rootfs: -1:1}-1))
current_kernfs=${current_rootfs: 0:-1}$current_kernfs_num

if [ ! -f /usr/share/vboot/devkeys/kernel.keyblock ]
then
  echo "ERROR: the ChromeOS signing keys (/usr/share/vboot/devkeys) are missing." >&2
  echo "       Make sure dev mode is on and the device was set up with" >&2
  echo "       chromeos-firmwareupdate --mode=todev." >&2
  exit 1
fi

vbutil_kernel --repack ${target_kern} \
    --oldblob $current_kernfs \
    --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
    --version 1 \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --config kernel-config \
    --arch $vbutil_arch

#Set Ubuntu kernel partition as top priority for next boot (and next boot only)
cgpt add -i 6 -P 5 -T 1 ${target_disk}

echo -e "

Installation seems to be complete. If ChrUbuntu fails when you reboot,
power off your Chrome OS device and then turn it back on. You'll be back
in Chrome OS. If you're happy with ChrUbuntu when you reboot be sure to run:

sudo cgpt add -i 6 -P 5 -S 1 ${target_disk}

To make it the default boot option (a ChromeOS update can reset this; run the
command again if the device boots back into ChromeOS). The ChrUbuntu login is:

Username:  user
Password:  user

Change that password right after the first login:

sudo passwd user

We're now ready to start ChrUbuntu!
"

read -p "Press [Enter] to reboot..."

# Release the chroot mounts before rebooting; the EXIT trap also does this,
# but doing it here keeps the filesystem clean for the shutdown that follows.
cleanup_chroot

reboot
