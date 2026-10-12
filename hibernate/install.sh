#!/bin/bash
# DKMS install for the IPU6/IVSC S4 overlay. Reboot after.
# ov02c10 must already provide i2c_device_id "ov02c10" (see patches/).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
NAME=mei-vsc-hibernate
VER=1.26
HOOK_SRC="$SRC/mei-vsc-hibernate-sleep.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Need root."
  exec sudo "$0" "$@"
fi

echo "Building $NAME $VER against $(uname -r)..."
make -C "$SRC" KERNEL_SRC=/lib/modules/$(uname -r)/build

echo "Registering DKMS..."
for old in 1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 1.12 1.13 1.14 1.15 1.16 1.17 1.18 1.19 1.20 1.21 1.22 1.23 1.24 1.25 "$VER"; do
  dkms remove "$NAME/$old" --all 2>/dev/null || true
done
rm -rf "/usr/src/${NAME}-${VER}"
mkdir -p "/usr/src/${NAME}-${VER}"
cp -a "$SRC"/. "/usr/src/${NAME}-${VER}/"
dkms add -m "$NAME" -v "$VER"
dkms install "$NAME/$VER"

HOOK_DST=
for d in /usr/lib/systemd/system-sleep /lib/systemd/system-sleep; do
  if [[ -d "$d" ]] && [[ -f "$HOOK_SRC" ]]; then
    install -m 0755 "$HOOK_SRC" "$d/mei-vsc-hibernate"
    echo "Installed sleep hook: $d/mei-vsc-hibernate"
    HOOK_DST=$d
    break
  fi
done

echo
echo "Installed. Reboot, then test camera, then two hibernates."
echo "modinfo ov02c10 must list alias i2c:ov02c10 or the post-S4 client will not bind."
echo "Cold boot must not Oops isys; PSYS must bind."
