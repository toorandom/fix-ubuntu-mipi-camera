#!/usr/bin/env bash
# ==============================================================================
# ipu6-camera-fix.sh
# ==============================================================================
# Questions: Eduardo Ruiz Duarte <toorandom@gmail.com>
#
# Make an Intel IPU6 MIPI camera work on Ubuntu — and keep it working across
# kernel upgrades.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# Intel's camera HAL (libcamhal, driven by the icamerasrc GStreamer element)
# needs the PSYS device node /dev/ipu-psys0. PSYS is the hardware ISP
# interface, and it only ever lived in Intel's out-of-tree IPU6 driver.
#
# Since kernel 6.10 the IPU6 driver is in-tree and ships ISYS only. When the
# out-of-tree intel-ipu6-psys module does not match the in-tree intel-ipu6 it
# loads, never probes, and /dev/ipu-psys0 never appears. Everything else still
# looks perfectly healthy — v4l2loopback loads, v4l2-relayd runs, /dev/videoN
# exists — but not a single frame is ever produced. The only visible clue is:
#
#   journalctl -u v4l2-relayd@default.service -b | grep CamHAL
#   CamHAL[ERR] Failed to open PSYS, error: No such file or directory
#
# That is why "my camera broke after a kernel upgrade" is so confusing, and
# why checking module signatures or reinstalling packages never helps.
#
# WHAT THIS SCRIPT DOES
#   - Picks the best pipeline that actually works on THIS kernel:
#       * icamerasrc   — Intel HAL, hardware ISP. Best image quality.
#                        Requires /dev/ipu-psys0.
#       * libcamerasrc — libcamera + software ISP. Works with the in-tree
#                        driver alone, so it survives any kernel upgrade.
#                        Greener and darker unless a sensor tuning file exists.
#     Both are fed into v4l2loopback, so the camera always shows up as a plain
#     /dev/videoN that every app understands — Zoom included, which does not
#     speak PipeWire camera.
#   - Verifies by actually capturing frames, never by assuming success
#   - Falls back from the HAL to libcamera automatically when the HAL yields
#     no frames
#   - Signs v4l2loopback for Secure Boot (MOK enrollment, two phases)
#   - Installs a kernel hook that re-signs after every kernel upgrade
#   - Refuses to keep an orphaned intel-ipu6-psys loaded: besides being
#     useless it NULL-derefs the kernel in isys_runtime_pm_suspend
#
# Supported hardware : Laptops with Intel IPU6 (ov02c10, ov08x40, ...)
# Supported OS       : Ubuntu 22.04 / 24.04 / 26.04
#
# Usage:
#   sudo bash ipu6-camera-fix.sh              # install / repair
#   sudo bash ipu6-camera-fix.sh --status     # diagnose only, change nothing
#   sudo bash ipu6-camera-fix.sh --libcamera  # force the libcamera pipeline
#   sudo bash ipu6-camera-fix.sh --hal        # force the Intel HAL pipeline
#   sudo bash ipu6-camera-fix.sh --uninstall  # remove everything
#   sudo bash ipu6-camera-fix.sh --yes        # never prompt
# ==============================================================================

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
SCRIPT_NAME="ipu6-camera-fix"
INSTALLED_SCRIPT="/usr/local/sbin/${SCRIPT_NAME}.sh"
STATE_DIR="/var/lib/${SCRIPT_NAME}"
MOK_PRIV="${STATE_DIR}/MOK.priv"
MOK_DER="${STATE_DIR}/MOK.der"
PHASE_FILE="${STATE_DIR}/phase"
MOK_CN="IPU6 Camera Module Signing Key"

MODPROBE_CONF="/etc/modprobe.d/v4l2loopback.conf"
MODULES_LOAD_CONF="/etc/modules-load.d/v4l2loopback.conf"
SIGN_SERVICE="/etc/systemd/system/sign-v4l2loopback.service"
SIGN_SCRIPT="/usr/local/sbin/sign-v4l2loopback.sh"

PSYS_GUARD="/usr/local/sbin/ipu6-psys-guard.sh"
PSYS_GUARD_CONF="/etc/modprobe.d/ipu6-psys-guard.conf"

KERNEL_HOOK="/etc/kernel/postinst.d/zy-${SCRIPT_NAME}"

V4L2_RELAYD_CONF="/etc/v4l2-relayd.d/default.conf"
CARD_LABEL="Intel MIPI Camera"

SRC_HAL="icamerasrc buffer-count=7"
SRC_LIBCAMERA="libcamerasrc"

# The Intel HAL emits black frames until auto-exposure converges, so
# verification has to discard the first couple of seconds.
VERIFY_FRAMES=60
VERIFY_MIN_BYTES=20000

ASSUME_YES=0
FORCE_SOURCE=""

# ── Logging ────────────────────────────────────────────────────────────────────
info()    { echo "  [•] $*"; }
ok()      { echo "  [✓] $*"; }
warn()    { echo "  [!] $*" >&2; }
die()     { echo "  [✗] $*" >&2; exit 1; }
section() { echo; echo "▸ $*"; echo "  $(printf '%.0s─' {1..60})"; }

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local ans
    read -rp "  $1 [Y/n]: " ans
    [[ ! "${ans:-y}" =~ ^[nN] ]]
}

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

get_phase() { [[ -f "$PHASE_FILE" ]] && cat "$PHASE_FILE" || echo "1"; }
set_phase() { echo "$1" > "$PHASE_FILE"; }

# ── Detectors ──────────────────────────────────────────────────────────────────
# NOTE: every check below captures output into a variable before filtering.
# With `set -o pipefail`, `cmd | grep -q` fails when grep exits early and the
# producer dies of SIGPIPE (141) — so the check would report the opposite of
# the truth precisely when the match is found fast.
secure_boot_on() {
    local out
    out=$(mokutil --sb-state 2>/dev/null) || true
    [[ "$out" == *"SecureBoot enabled"* ]]
}

# /sys/module is authoritative and needs no pipeline at all.
module_loaded() { [[ -d "/sys/module/${1//-/_}" ]]; }

key_enrolled() {
    [[ -f "$MOK_DER" ]] || return 1
    local out
    out=$(mokutil --test-key "$MOK_DER" 2>/dev/null) || true
    grep -qE "is (already )?enrolled" <<< "$out"
}

has_element() { gst-inspect-1.0 "$1" &>/dev/null 2>&1; }

# The HAL is usable only when the PSYS node exists. The rest of the Intel stack
# can be perfectly installed and still produce nothing without it.
hal_available() { [[ -e /dev/ipu-psys0 ]] && has_element icamerasrc; }

libcamera_available() {
    has_element libcamerasrc || return 1
    command -v cam &>/dev/null || return 0
    local out
    out=$(cam -l 2>/dev/null) || true
    grep -qE "^[0-9]+: " <<< "$out"
}

# Find the loopback node by label: other v4l2loopback devices (OBS, DroidCam)
# may exist, and picking the first one blindly would target the wrong device.
camera_device() {
    local p
    for p in /sys/devices/virtual/video4linux/video*; do
        [[ -e "$p" ]] || continue
        [[ "$(cat "$p/name" 2>/dev/null)" == "$CARD_LABEL" ]] || continue
        basename "$p"
        return 0
    done
    return 1
}

current_source() {
    [[ -f "$V4L2_RELAYD_CONF" ]] || return 1
    local out
    out=$(sed -n 's/^VIDEOSRC=//p' "$V4L2_RELAYD_CONF") || true
    printf '%s\n' "$out" | head -1
}

# ── Packages ───────────────────────────────────────────────────────────────────
install_packages() {
    section "Installing packages"
    local kver; kver=$(uname -r)
    local pkgs=(mokutil openssl v4l2loopback-dkms zstd ffmpeg v4l-utils gstreamer1.0-tools)

    local pkg
    for pkg in v4l2-relayd gstreamer1.0-icamera gstreamer1.0-libcamera \
               libcamera-tools libcamera-ipa; do
        apt-cache show "$pkg" &>/dev/null 2>&1 && pkgs+=("$pkg")
    done

    [[ -f "/usr/src/linux-headers-${kver}/scripts/sign-file" ]] || pkgs+=("linux-headers-${kver}")

    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    ok "Packages ready"
}

# ── Orphaned PSYS guard ────────────────────────────────────────────────────────
# A plain blacklist would be wrong: kernels shipping Intel's complete
# out-of-tree stack genuinely need this module, and on those it is what gives
# you the hardware ISP. The decision can only be made at load time.
install_psys_guard() {
    section "Installing intel-ipu6-psys load guard"

    cat > "$PSYS_GUARD" <<'EOF'
#!/usr/bin/env bash
# Keep intel-ipu6-psys loaded only if it actually probed. Against a mismatched
# in-tree intel-ipu6 it never creates /dev/ipu-psys0 and corrupts ISYS runtime
# PM (NULL deref in isys_runtime_pm_suspend). Installed by ipu6-camera-fix.sh.
modprobe --ignore-install intel-ipu6-psys "$@" || exit 0

for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e /dev/ipu-psys0 ] && exit 0
    sleep 0.2
done

logger -t ipu6-psys-guard \
    "intel-ipu6-psys loaded but /dev/ipu-psys0 never appeared; unloading to protect ISYS"
modprobe -r intel-ipu6-psys 2>/dev/null || true
exit 0
EOF
    chmod 755 "$PSYS_GUARD"

    cat > "$PSYS_GUARD_CONF" <<EOF
# Generated by ${SCRIPT_NAME}
install intel-ipu6-psys ${PSYS_GUARD} \$CMDLINE_OPTS
EOF
    ok "Guard installed"
}

# ── DKMS + Secure Boot signing ────────────────────────────────────────────────
ensure_dkms_built() {
    local kver="${1:-$(uname -r)}"
    modinfo -k "$kver" -n v4l2loopback &>/dev/null && return 0
    info "Building DKMS module for kernel $kver..."
    local st ver
    st=$(dkms status v4l2loopback 2>/dev/null) || true
    ver=$(grep -oP '\d+\.\d+\.\d+' <<< "$st" | head -1) || true
    [[ -n "$ver" ]] || die "v4l2loopback not found in DKMS"
    dkms install "v4l2loopback/${ver}" -k "$kver" --force
}

sign_module() {
    local kver="${1:-$(uname -r)}"
    local sign_file="/usr/src/linux-headers-${kver}/scripts/sign-file"

    [[ -f "$sign_file" ]] || die "sign-file not found for kernel $kver — install linux-headers-$kver"
    [[ -f "$MOK_PRIV" && -f "$MOK_DER" ]] || die "MOK keys missing in $STATE_DIR"

    ensure_dkms_built "$kver"
    local module_path; module_path=$(modinfo -k "$kver" -n v4l2loopback)
    info "Signing: $module_path"

    local tmp="/tmp/${SCRIPT_NAME}_$$.ko" ext=""
    [[ "$module_path" == *.ko.zst ]] && ext=".zst"
    [[ "$module_path" == *.ko.gz  ]] && ext=".gz"
    [[ "$module_path" == *.ko.xz  ]] && ext=".xz"

    case "$ext" in
        ".zst")
            cp "$module_path" "${tmp}.zst"; chmod 644 "${tmp}.zst"
            zstd -d "${tmp}.zst" -o "$tmp" --force
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            zstd -f "$tmp" -o "${tmp}.new"; cp "${tmp}.new" "$module_path"
            rm -f "$tmp" "${tmp}.zst" "${tmp}.new" ;;
        ".gz")
            cp "$module_path" "${tmp}.gz"; gunzip -f "${tmp}.gz"
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            gzip -f "$tmp"; cp "${tmp}.gz" "$module_path"
            rm -f "$tmp" "${tmp}.gz" ;;
        ".xz")
            cp "$module_path" "${tmp}.xz"; xz -d "${tmp}.xz"
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            xz "$tmp"; cp "${tmp}.xz" "$module_path"
            rm -f "$tmp" "${tmp}.xz" ;;
        *)  "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$module_path" ;;
    esac
    ok "Module signed for kernel $kver"
}

generate_mok_keys() {
    if [[ -f "$MOK_PRIV" && -f "$MOK_DER" ]]; then
        ok "MOK keys already exist, reusing"
        return
    fi
    info "Generating RSA-2048 MOK key pair..."
    openssl req -new -x509 -newkey rsa:2048 -keyout "$MOK_PRIV" \
        -outform DER -out "$MOK_DER" -days 36500 \
        -subj "/CN=${MOK_CN}/" -nodes 2>/dev/null
    chmod 600 "$MOK_PRIV"
    ok "Keys generated in $STATE_DIR"
}

install_signing_service() {
    section "Installing boot signing service"
    cat > "$SIGN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Re-signs v4l2loopback for the running kernel. Installed by ipu6-camera-fix.sh.
set -euo pipefail
STATE_DIR="/var/lib/ipu6-camera-fix"
MOK_PRIV="${STATE_DIR}/MOK.priv"; MOK_DER="${STATE_DIR}/MOK.der"
kver=$(uname -r); sign_file="/usr/src/linux-headers-${kver}/scripts/sign-file"
[[ -f "$MOK_PRIV" && -f "$MOK_DER" ]] || { echo "[sign-v4l2loopback] no MOK keys, skipping"; exit 0; }
[[ -f "$sign_file" ]] || { echo "[sign-v4l2loopback] no sign-file for $kver"; exit 0; }
module_path=$(modinfo -k "$kver" -n v4l2loopback 2>/dev/null) || { echo "[sign-v4l2loopback] module not found"; exit 0; }
tmp="/tmp/sign_v4l2loopback_$$.ko"; ext=""
[[ "$module_path" == *.ko.zst ]] && ext=".zst"
[[ "$module_path" == *.ko.gz  ]] && ext=".gz"
[[ "$module_path" == *.ko.xz  ]] && ext=".xz"
case "$ext" in
    ".zst") cp "$module_path" "${tmp}.zst"; chmod 644 "${tmp}.zst"
            zstd -d "${tmp}.zst" -o "$tmp" --force
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            zstd -f "$tmp" -o "${tmp}.new"; cp "${tmp}.new" "$module_path"
            rm -f "$tmp" "${tmp}.zst" "${tmp}.new" ;;
    ".gz")  cp "$module_path" "${tmp}.gz"; gunzip -f "${tmp}.gz"
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            gzip -f "$tmp"; cp "${tmp}.gz" "$module_path"; rm -f "$tmp" "${tmp}.gz" ;;
    ".xz")  cp "$module_path" "${tmp}.xz"; xz -d "${tmp}.xz"
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            xz "$tmp"; cp "${tmp}.xz" "$module_path"; rm -f "$tmp" "${tmp}.xz" ;;
    *)      "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$module_path" ;;
esac
echo "[sign-v4l2loopback] signed for kernel $kver: $module_path"
EOF
    chmod 755 "$SIGN_SCRIPT"

    cat > "$SIGN_SERVICE" <<EOF
[Unit]
Description=Sign v4l2loopback for Secure Boot (kernel-update safe)
DefaultDependencies=no
Before=modprobe@v4l2loopback.service systemd-modules-load.service modules-load.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${SIGN_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
    systemctl daemon-reload
    systemctl enable sign-v4l2loopback.service
    ok "Boot signing service enabled"
}

# ── Kernel upgrade hook ────────────────────────────────────────────────────────
install_kernel_hook() {
    section "Installing kernel upgrade hook"
    install -D -m 755 "$0" "$INSTALLED_SCRIPT"
    cat > "$KERNEL_HOOK" <<EOF
#!/bin/sh
# Generated by ${SCRIPT_NAME}. Must never fail a kernel package install.
[ -x "${INSTALLED_SCRIPT}" ] || exit 0
"${INSTALLED_SCRIPT}" --kernel-hook "\$@" || true
exit 0
EOF
    chmod 755 "$KERNEL_HOOK"
    ok "Hook installed: $KERNEL_HOOK"
}

run_kernel_hook() {
    local k="${1:-$(uname -r)}"
    if secure_boot_on && [[ -f "$MOK_PRIV" ]] \
       && [[ -f "/usr/src/linux-headers-${k}/scripts/sign-file" ]]; then
        sign_module "$k" || true
    fi
    # Whether PSYS exists is a property of the kernel being booted, so the
    # pipeline choice must be re-validated rather than inherited.
    rm -f "${STATE_DIR}/verified"
    exit 0
}

# ── Configuration ──────────────────────────────────────────────────────────────
configure_boot_loading() {
    section "Configuring boot persistence"
    cat > "$MODPROBE_CONF" <<EOF
# Generated by ${SCRIPT_NAME}
options v4l2loopback exclusive_caps=1 card_label="${CARD_LABEL}"
EOF
    echo "v4l2loopback" > "$MODULES_LOAD_CONF"
    ok "v4l2loopback will load at boot as: $CARD_LABEL"
}

# v4l2-relayd accepts an arbitrary GStreamer source, which is what makes
# switching between the Intel HAL and libcamera a single line of config.
write_relayd_conf() {
    local src="$1"
    mkdir -p /etc/v4l2-relayd.d
    cat > "$V4L2_RELAYD_CONF" <<EOF
# Generated by ${SCRIPT_NAME}
VIDEOSRC=${src}
FORMAT=NV12
WIDTH=1280
HEIGHT=720
FRAMERATE=30/1
CARD_LABEL=${CARD_LABEL}
EOF
}

load_module() {
    depmod -a
    if module_loaded v4l2loopback; then
        modprobe -r v4l2loopback 2>/dev/null || true
    fi
    modprobe v4l2loopback
    ok "v4l2loopback loaded"
}

restart_relayd() {
    systemctl reset-failed 'v4l2-relayd@*' 2>/dev/null || true
    systemctl enable --now v4l2-relayd@default.service
    sleep 3
}

# ── Verification ───────────────────────────────────────────────────────────────
# Health is "a frame came out", never "the services look up": every component
# can be green while the HAL silently fails to configure its pipeline.
capture_works() {
    local dev="$1" out="/tmp/${SCRIPT_NAME}_verify_$$.png" rc=1
    command -v ffmpeg &>/dev/null || { warn "ffmpeg missing — cannot verify"; return 0; }
    rm -f "$out"
    timeout 60 ffmpeg -hide_banner -loglevel error -f v4l2 -i "/dev/${dev}" \
        -frames:v "$VERIFY_FRAMES" -vsync 0 -update 1 -y "$out" &>/dev/null || true
    # An all-black frame compresses to almost nothing, so size is the test.
    if [[ -s "$out" ]] && [[ "$(stat -c%s "$out")" -gt "$VERIFY_MIN_BYTES" ]]; then
        rc=0
    fi
    rm -f "$out"
    return $rc
}

try_source() {
    local src="$1" label="$2" dev
    info "Trying pipeline: ${label}"
    write_relayd_conf "$src"
    restart_relayd
    dev=$(camera_device) || { warn "No /dev/videoN labelled '$CARD_LABEL'"; return 1; }
    if capture_works "$dev"; then
        ok "${label} works — camera live on /dev/${dev}"
        return 0
    fi
    warn "${label} produced no usable frames"
    return 1
}

setup_pipeline() {
    section "Selecting camera pipeline"

    if [[ "$FORCE_SOURCE" == "hal" ]]; then
        hal_available || die "HAL unavailable: /dev/ipu-psys0 missing or icamerasrc not installed"
        try_source "$SRC_HAL" "Intel HAL (hardware ISP)" && return 0
        die "Forced HAL pipeline produced no frames"
    fi
    if [[ "$FORCE_SOURCE" == "libcamera" ]]; then
        libcamera_available || die "libcamera unavailable: install gstreamer1.0-libcamera libcamera-ipa"
        try_source "$SRC_LIBCAMERA" "libcamera + software ISP" && return 0
        die "Forced libcamera pipeline produced no frames"
    fi

    # Prefer the HAL: a hardware ISP means correct exposure and white balance.
    if hal_available; then
        info "/dev/ipu-psys0 present — the Intel HAL is available"
        try_source "$SRC_HAL" "Intel HAL (hardware ISP)" && return 0
        warn "Falling back to libcamera"
    else
        info "/dev/ipu-psys0 absent — this kernel cannot drive the Intel HAL"
    fi

    if libcamera_available; then
        try_source "$SRC_LIBCAMERA" "libcamera + software ISP" && return 0
    else
        warn "libcamera pipeline unavailable (install gstreamer1.0-libcamera libcamera-ipa)"
    fi

    return 1
}

# ── Status ─────────────────────────────────────────────────────────────────────
cmd_status() {
    local dev; dev=$(camera_device || echo "")
    section "Diagnosis"
    echo "  Kernel            : $(uname -r)"
    echo "  Ubuntu            : $(lsb_release -ds 2>/dev/null || echo '?')"
    echo "  intel-ipu6        : $(modinfo -n intel-ipu6 2>/dev/null || echo 'not found')"
    echo "  /dev/ipu-psys0    : $([[ -e /dev/ipu-psys0 ]] && echo 'present (HAL usable)' || echo 'MISSING (HAL impossible)')"
    echo "  icamerasrc        : $(has_element icamerasrc && echo present || echo missing)"
    echo "  libcamerasrc      : $(has_element libcamerasrc && echo present || echo missing)"
    echo "  Secure Boot       : $(secure_boot_on && echo enabled || echo disabled)"
    echo "  MOK enrolled      : $(key_enrolled && echo yes || echo no)"
    echo "  v4l2loopback      : $(module_loaded v4l2loopback && echo loaded || echo 'not loaded')"
    echo "  v4l2-relayd       : $(systemctl is-active 'v4l2-relayd@default.service' 2>/dev/null || true)"
    echo "  Active pipeline   : $(current_source 2>/dev/null || echo 'not configured')"
    echo "  Camera node       : $([[ -n "$dev" ]] && echo "/dev/$dev" || echo none)"
    echo "  PSYS guard        : $([[ -f "$PSYS_GUARD_CONF" ]] && echo installed || echo 'not installed')"
    echo "  Kernel hook       : $([[ -f "$KERNEL_HOOK" ]] && echo installed || echo 'not installed')"

    if [[ -n "$dev" ]]; then
        section "Live capture test"
        if capture_works "$dev"; then
            ok "Camera is delivering frames"
        else
            warn "Camera is NOT delivering frames — re-run without --status to repair"
        fi
    fi

    local sync; sync=$(dmesg 2>/dev/null | grep -cE 'Frame sync error' || true)
    if [[ "${sync:-0}" -gt 0 ]]; then
        echo
        info "CSI-2 'Frame sync error' seen ${sync} time(s) this boot."
        info "If the image freezes on the last frame, restart the pipeline:"
        info "    sudo systemctl restart v4l2-relayd@default.service"
    fi
}

# ── Uninstall ──────────────────────────────────────────────────────────────────
uninstall() {
    section "Uninstall"
    systemctl disable --now sign-v4l2loopback.service 2>/dev/null || true
    systemctl disable --now v4l2-relayd@default.service 2>/dev/null || true
    if module_loaded v4l2loopback; then
        modprobe -r v4l2loopback 2>/dev/null || true
    fi

    rm -f "$MODPROBE_CONF" "$MODULES_LOAD_CONF" "$SIGN_SERVICE" "$SIGN_SCRIPT"
    rm -f "$V4L2_RELAYD_CONF" "$PSYS_GUARD_CONF" "$PSYS_GUARD"
    rm -f "$KERNEL_HOOK" "$INSTALLED_SCRIPT"
    systemctl daemon-reload
    ok "Files, guard, hook and services removed"

    local was_enrolled=false
    if [[ -f "$MOK_DER" ]] && key_enrolled; then
        was_enrolled=true
        echo
        info "Queueing MOK key deletion from firmware..."
        echo "  You will be asked for a temporary password; you re-enter it at"
        echo "  the blue MOK Manager screen after rebooting."
        echo
        mokutil --delete "$MOK_DER" || true
    fi

    rm -rf "$STATE_DIR"
    ok "State directory removed"
    echo
    echo "  Uninstall complete. Reboot to finish."
    if $was_enrolled; then
        echo "  At the blue screen: Delete MOK → Continue → Yes → password → Reboot."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
ACTION="install"; HOOK_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall)   ACTION="uninstall" ;;
        --status|-s)   ACTION="status" ;;
        --kernel-hook) ACTION="hook"; shift; HOOK_ARGS=("$@"); break ;;
        --libcamera)   FORCE_SOURCE="libcamera" ;;
        --hal)         FORCE_SOURCE="hal" ;;
        --phase2)      set_phase "2" ;;
        --yes|-y)      ASSUME_YES=1 ;;
        -h|--help)     awk 'NR>1{ if(/^#/){sub(/^# ?/,""); print} else exit }' "$0"; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

case "$ACTION" in
    uninstall) uninstall; exit 0 ;;
    status)    cmd_status; exit 0 ;;
    hook)      run_kernel_hook "${HOOK_ARGS[0]:-}" ;;
esac

echo
echo "┌──────────────────────────────────────────────────┐"
echo "│          Intel IPU6 Camera Fix for Ubuntu        │"
echo "│  Questions: Eduardo Ruiz Duarte                  │"
echo "│  toorandom@gmail.com                             │"
echo "└──────────────────────────────────────────────────┘"

KVER=$(uname -r)
section "Environment"
echo "  Kernel         : $KVER"
echo "  Ubuntu         : $(lsb_release -ds 2>/dev/null || echo '?')"
echo "  /dev/ipu-psys0 : $([[ -e /dev/ipu-psys0 ]] && echo present || echo missing)"

install_packages
install_psys_guard
configure_boot_loading

# ── Secure Boot: sign v4l2loopback before loading it ─────────────────────────
if secure_boot_on; then
    info "Secure Boot: enabled"
    phase=$(get_phase)

    if [[ "$phase" == "1" ]]; then
        section "Phase 1 — MOK key enrollment"
        generate_mok_keys
        if key_enrolled; then
            ok "Key already enrolled — continuing"
            set_phase "2"
        else
            echo
            info "Enrolling key with MOK..."
            echo "  You will be asked for a temporary password. Write it down:"
            echo "  you must type it at the blue MOK Manager screen after rebooting."
            echo
            mokutil --import "$MOK_DER"
            set_phase "2"
            echo
            echo "  ┌──────────────────────────────────────────────────────────┐"
            echo "  │  REBOOT REQUIRED — at the blue MOK Manager screen:       │"
            echo "  │    1. Enroll MOK   2. Continue   3. Yes                  │"
            echo "  │    4. Enter the password you just created   5. Reboot    │"
            echo "  │                                                          │"
            echo "  │  Then run this script again to finish.                   │"
            echo "  └──────────────────────────────────────────────────────────┘"
            echo
            if confirm "Reboot now?"; then reboot; fi
            info "Reboot postponed. Re-run this script after enrolling the key."
            exit 0
        fi
    fi

    section "Phase 2 — Signing"
    rm -f "$PHASE_FILE"
    key_enrolled || die "MOK key not enrolled in firmware. Did you finish the blue screen? Re-run to retry."
    sign_module "$KVER"
    install_signing_service
else
    info "Secure Boot: disabled — no module signing needed"
fi

load_module
install_kernel_hook

if setup_pipeline; then
    CAM=$(camera_device || echo "video?")
    echo
    section "Done"
    ok "Camera is live at /dev/${CAM}"
    echo "  Pipeline : $(current_source)"
    echo
    echo "  Test it with:"
    echo "      ffplay -f v4l2 -i /dev/${CAM}"
    echo
    echo "  Works in any app that reads /dev/videoN, Zoom included."
    exit 0
fi

echo
warn "No pipeline produced frames on this kernel."
warn "Run 'sudo bash $0 --status' for a full diagnosis."
if [[ ! -e /dev/ipu-psys0 ]]; then
    warn "/dev/ipu-psys0 is missing, so the Intel HAL cannot work here."
    warn "Try the libcamera pipeline instead:"
    warn "    sudo apt install gstreamer1.0-libcamera libcamera-ipa libcamera-tools"
    warn "    sudo bash $0 --libcamera"
fi
exit 1
