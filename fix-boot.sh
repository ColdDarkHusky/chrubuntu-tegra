#!/bin/bash
# fix-boot.sh - make a finished ChrUbuntu install actually boot
#
# Run in a ChromeOS dev-mode shell (Ctrl-Alt-T, type "shell"):
#   curl -sL https://is.gd/chrubuntu_fix | sudo bash
#
# It sets the two firmware flags the installer needs, finds the disk that
# holds the Ubuntu root filesystem, and re-arms its kernel partition. Safe to
# run more than once.

set -u

say()  { echo "==> $*"; }
note() { echo "    $*"; }
fail() { echo "" >&2; echo "ERROR: $*" >&2; exit 1; }

[ "`id -u`" = "0" ] || fail "run with sudo: curl -sL https://is.gd/chrubuntu_fix | sudo bash"

if ! command -v crossystem >/dev/null 2>&1 || ! command -v cgpt >/dev/null 2>&1
then
  fail "crossystem/cgpt not found. Run this in the ChromeOS shell
       (Ctrl-Alt-T, type 'shell'), not inside Ubuntu and not in crosh itself."
fi

say "1/4 firmware boot flags"
crossystem dev_boot_signed_only=0 >/dev/null 2>&1 || true
crossystem dev_boot_usb=1 >/dev/null 2>&1 || true
usb="`crossystem dev_boot_usb 2>/dev/null || true`"
signed_only="`crossystem dev_boot_signed_only 2>/dev/null || true`"
note "dev_boot_usb=$usb  dev_boot_signed_only=$signed_only"
if [ "$signed_only" != "0" ]
then
  fail "the firmware still reports dev_boot_signed_only=$signed_only.
       Your device is not in developer mode, so it will not boot an
       unsigned kernel. Enable developer mode first."
fi

say "2/4 finding the ChrUbuntu install"
found=""
found_part=""
for disk in /dev/mmcblk1 /dev/mmcblk0 /dev/sda /dev/sdb
do
  part=""
  if [ -b "${disk}p7" ]; then
    part="${disk}p7"
  elif [ -b "${disk}7" ]; then
    part="${disk}7"
  fi
  [ -n "$part" ] || continue

  mp="`mktemp -d`"
  if mount -o ro "$part" "$mp" 2>/dev/null
  then
    if [ -f "$mp/etc/hostname" ] && grep -qx chrubuntu "$mp/etc/hostname" 2>/dev/null
    then
      found="$disk"
      found_part="$part"
    fi
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
  fi
  rmdir "$mp" 2>/dev/null || true

  [ -z "$found" ] || break
done

if [ -z "$found" ]
then
  fail "no partition with a ChrUbuntu root filesystem was found.
       Either the install did not finish or it went to a disk this run
       cannot see. Re-run the installer and check its last lines."
fi
note "root filesystem: $found_part (on $found)"

say "3/4 arming the kernel partition"
if [ -b "${found}p6" ]; then
  kern="${found}p6"
else
  kern="${found}6"
fi
[ -b "$kern" ] || fail "kernel partition $kern does not exist; the install is incomplete."
cgpt add -i 6 -P 5 -S 1 "$found" || fail "cgpt could not update $found"
cgpt show -i 6 -P -S -T "$found" 2>/dev/null | while read -r v; do note "$v"; done

say "4/4 kernel signature"
if command -v vbutil_kernel >/dev/null 2>&1
then
  vbutil_kernel --verify "$kern" 2>&1 | tail -4 | while read -r l; do note "$l"; done
else
  note "vbutil_kernel not available, skipping the signature check"
fi

cat <<'EOF'

Done. Power the Chromebook fully off (not reboot), leave the card in, and
power it on. Do not press Ctrl-D - that boots the internal disk - and do not
press anything else; the firmware tries the card by itself.

If it still starts ChromeOS, run this once and send me the output:
  sudo bash -x <(curl -sL https://is.gd/chrubuntu_fix)
EOF
