#!/usr/bin/env bash
# ==============================================================================
# ipu6-camera-fix.sh
# ==============================================================================
# Questions: Eduardo Ruiz Duarte <toorandom@gmail.com>
#
# Fix Intel IPU6 camera on Ubuntu — with or without Secure Boot.
#
# What it does:
#   - Installs v4l2loopback-dkms, v4l2-relayd, and Intel IPU6 GStreamer plugin
#   - If Secure Boot is ON: generates a MOK key, enrolls it, and automatically
#     signs the module after reboot (no manual steps beyond MOK Manager)
#   - If Secure Boot is OFF: installs and loads everything in one shot
#   - Installs a boot service that re-signs the module on kernel updates
#   - Configures v4l2-relayd so the camera appears as a standard /dev/videoN
#
# Supported hardware : Laptops with Intel IPU6 (ov02c10, ov08x40, etc.)
# Supported OS       : Ubuntu 22.04 / 24.04
# Supported kernels  : 6.8 and newer
#
# Usage:
#   sudo bash ipu6-camera-fix.sh
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

V4L2_RELAYD_CONF="/etc/v4l2-relayd.d/default.conf"
CARD_LABEL="Intel MIPI Camera"

# ── Logging ────────────────────────────────────────────────────────────────────
info()    { echo "  [•] $*"; }
ok()      { echo "  [✓] $*"; }
warn()    { echo "  [!] $*" >&2; }
die()     { echo "  [✗] $*" >&2; exit 1; }
section() { echo; echo "▸ $*"; echo "  $(printf '%.0s─' {1..50})"; }

# ── Root check ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# ── Phase helpers ──────────────────────────────────────────────────────────────
get_phase()   { [[ -f "$PHASE_FILE" ]] && cat "$PHASE_FILE" || echo "1"; }
set_phase()   { echo "$1" > "$PHASE_FILE"; }

# ── Detectors ──────────────────────────────────────────────────────────────────
secure_boot_on() {
    mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"
}

key_enrolled() {
    if [[ ! -f "$MOK_DER" ]]; then return 1; fi
    local out
    out=$(mokutil --test-key "$MOK_DER" 2>/dev/null) || true
    grep -qE "is (already )?enrolled" <<< "$out"
}

has_icamerasrc() {
    gst-inspect-1.0 icamerasrc &>/dev/null 2>&1
}

# ── Install packages ───────────────────────────────────────────────────────────
install_packages() {
    section "Installing packages"
    local kver; kver=$(uname -r)
    local pkgs=(mokutil openssl v4l2loopback-dkms zstd ffmpeg v4l-utils gstreamer1.0-tools)

    # IPU6-specific packages (install if available in apt)
    for pkg in v4l2-relayd gstreamer1.0-icamera; do
        apt-cache show "$pkg" &>/dev/null 2>&1 && pkgs+=("$pkg")
    done

    # Kernel headers needed for sign-file
    [[ -f "/usr/src/linux-headers-${kver}/scripts/sign-file" ]] || \
        pkgs+=("linux-headers-${kver}")

    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    ok "Packages ready"
}

# ── DKMS: ensure module is built for current kernel ───────────────────────────
ensure_dkms_built() {
    local kver="${1:-$(uname -r)}"
    if modinfo -k "$kver" -n v4l2loopback &>/dev/null; then
        return 0
    fi
    info "Building DKMS module for kernel $kver..."
    local ver; ver=$(dkms status v4l2loopback 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
    [[ -n "$ver" ]] || die "v4l2loopback not found in DKMS"
    dkms install "v4l2loopback/${ver}" -k "$kver" --force
}

# ── Sign module — handles .ko / .ko.gz / .ko.xz / .ko.zst ────────────────────
sign_module() {
    local kver="${1:-$(uname -r)}"
    local sign_file="/usr/src/linux-headers-${kver}/scripts/sign-file"

    [[ -f "$sign_file" ]] || \
        die "sign-file not found for kernel $kver — install: linux-headers-$kver"
    [[ -f "$MOK_PRIV" && -f "$MOK_DER" ]] || \
        die "MOK keys missing in $STATE_DIR"

    ensure_dkms_built "$kver"
    local module_path; module_path=$(modinfo -k "$kver" -n v4l2loopback)
    info "Signing: $module_path"

    local tmp="/tmp/${SCRIPT_NAME}_$$.ko"

    local ext=""
    [[ "$module_path" == *.ko.zst ]] && ext=".zst"
    [[ "$module_path" == *.ko.gz  ]] && ext=".gz"
    [[ "$module_path" == *.ko.xz  ]] && ext=".xz"

    case "$ext" in
        ".zst")
            cp "$module_path" "${tmp}.zst"
            chmod 644 "${tmp}.zst"
            zstd -d "${tmp}.zst" -o "$tmp" --force
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            zstd -f "$tmp" -o "${tmp}.new"
            cp "${tmp}.new" "$module_path"
            rm -f "$tmp" "${tmp}.zst" "${tmp}.new"
            ;;
        ".gz")
            cp "$module_path" "${tmp}.gz"
            gunzip -f "${tmp}.gz"
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            gzip -f "$tmp"
            cp "${tmp}.gz" "$module_path"
            rm -f "$tmp" "${tmp}.gz"
            ;;
        ".xz")
            cp "$module_path" "${tmp}.xz"
            xz -d "${tmp}.xz"
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
            xz "$tmp"
            cp "${tmp}.xz" "$module_path"
            rm -f "$tmp" "${tmp}.xz"
            ;;
        *)
            "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$module_path"
            ;;
    esac
    ok "Module signed for kernel $kver"
}

# ── Generate MOK keys ──────────────────────────────────────────────────────────
generate_mok_keys() {
    if [[ -f "$MOK_PRIV" && -f "$MOK_DER" ]]; then
        ok "MOK keys already exist, reusing"
        return
    fi
    info "Generating RSA-2048 MOK key pair..."
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout "$MOK_PRIV" \
        -outform DER -out "$MOK_DER" \
        -days 36500 \
        -subj "/CN=${MOK_CN}/" \
        -nodes 2>/dev/null
    chmod 600 "$MOK_PRIV"
    ok "Keys generated in $STATE_DIR"
}

# ── Boot signing script (re-signs on every kernel update) ─────────────────────
install_signing_service() {
    section "Installing boot signing service"

    # The script that runs at boot
    cat > "$SIGN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Automatically re-signs v4l2loopback for the running kernel.
# Installed by ipu6-camera-fix.sh — runs before modules are loaded.
set -euo pipefail

STATE_DIR="/var/lib/ipu6-camera-fix"
MOK_PRIV="${STATE_DIR}/MOK.priv"
MOK_DER="${STATE_DIR}/MOK.der"
kver=$(uname -r)
sign_file="/usr/src/linux-headers-${kver}/scripts/sign-file"

[[ -f "$MOK_PRIV" && -f "$MOK_DER" ]] || { echo "[sign-v4l2loopback] MOK keys not found, skipping"; exit 0; }
[[ -f "$sign_file" ]]                  || { echo "[sign-v4l2loopback] sign-file not found for $kver (install linux-headers-$kver)"; exit 0; }

module_path=$(modinfo -k "$kver" -n v4l2loopback 2>/dev/null) || { echo "[sign-v4l2loopback] module not found for $kver"; exit 0; }

tmp="/tmp/sign_v4l2loopback_$$.ko"
ext=""
[[ "$module_path" == *.ko.zst ]] && ext=".zst"
[[ "$module_path" == *.ko.gz  ]] && ext=".gz"
[[ "$module_path" == *.ko.xz  ]] && ext=".xz"

case "$ext" in
    ".zst")
        cp "$module_path" "${tmp}.zst"; chmod 644 "${tmp}.zst"
        zstd -d "${tmp}.zst" -o "$tmp" --force
        "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
        zstd -f "$tmp" -o "${tmp}.new"
        cp "${tmp}.new" "$module_path"
        rm -f "$tmp" "${tmp}.zst" "${tmp}.new"
        ;;
    ".gz")
        cp "$module_path" "${tmp}.gz"; gunzip -f "${tmp}.gz"
        "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
        gzip -f "$tmp"; cp "${tmp}.gz" "$module_path"
        rm -f "$tmp" "${tmp}.gz"
        ;;
    ".xz")
        cp "$module_path" "${tmp}.xz"; xz -d "${tmp}.xz"
        "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$tmp"
        xz "$tmp"; cp "${tmp}.xz" "$module_path"
        rm -f "$tmp" "${tmp}.xz"
        ;;
    *)
        "$sign_file" sha256 "$MOK_PRIV" "$MOK_DER" "$module_path"
        ;;
esac

echo "[sign-v4l2loopback] signed for kernel $kver: $module_path"
EOF
    chmod 755 "$SIGN_SCRIPT"

    # Systemd unit — runs before modules are loaded
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
    ok "Boot signing service enabled (handles future kernel updates)"
}


# ── Configure v4l2loopback boot loading ───────────────────────────────────────
configure_boot_loading() {
    section "Configuring boot persistence"

    cat > "$MODPROBE_CONF" <<EOF
# Generated by ${SCRIPT_NAME}
options v4l2loopback exclusive_caps=1 card_label="${CARD_LABEL}"
EOF
    echo "v4l2loopback" > "$MODULES_LOAD_CONF"

    ok "v4l2loopback will load at boot with label: $CARD_LABEL"
}

# ── Configure v4l2-relayd ──────────────────────────────────────────────────────
configure_v4l2relayd() {
    if ! command -v v4l2-relayd &>/dev/null; then
        warn "v4l2-relayd not installed, skipping"
        return
    fi
    if ! has_icamerasrc; then
        warn "icamerasrc GStreamer plugin not found, skipping v4l2-relayd config"
        return
    fi

    section "Configuring v4l2-relayd (Intel IPU6 pipeline)"
    mkdir -p /etc/v4l2-relayd.d

    cat > "$V4L2_RELAYD_CONF" <<EOF
# Generated by ${SCRIPT_NAME}
VIDEOSRC=icamerasrc buffer-count=7
FORMAT=NV12
WIDTH=1280
HEIGHT=720
FRAMERATE=30/1
CARD_LABEL=${CARD_LABEL}
EOF
    ok "v4l2-relayd configured"
}

# ── Load module and start camera ───────────────────────────────────────────────
load_and_start() {
    section "Loading camera"

    depmod -a

    # Remove stale module if loaded
    if lsmod | grep -q v4l2loopback; then
        modprobe -r v4l2loopback 2>/dev/null || true
    fi
    modprobe v4l2loopback
    ok "v4l2loopback loaded"

    # Start v4l2-relayd
    if command -v v4l2-relayd &>/dev/null && has_icamerasrc; then
        systemctl reset-failed 'v4l2-relayd@*' 2>/dev/null || true
        systemctl enable --now v4l2-relayd@default.service
        sleep 1

        local cam_dev
        cam_dev=$(grep -rl "$CARD_LABEL" /sys/devices/virtual/video4linux/*/name 2>/dev/null \
                  | head -1 | cut -d/ -f6 || echo "")
        if [[ -n "$cam_dev" ]]; then
            ok "Camera available at: /dev/${cam_dev}"
        else
            warn "Module loaded but camera device not yet visible — try: v4l2-ctl --list-devices"
        fi
    fi
}

# ── Uninstall everything ───────────────────────────────────────────────────────
uninstall() {
    section "Uninstall — removing IPU6 camera fix"

    # 1. Parar y deshabilitar servicios
    if systemctl is-enabled sign-v4l2loopback.service &>/dev/null; then
        systemctl disable --now sign-v4l2loopback.service 2>/dev/null || true
        ok "Signing service disabled"
    fi
    if systemctl is-active 'v4l2-relayd@default.service' &>/dev/null; then
        systemctl disable --now v4l2-relayd@default.service 2>/dev/null || true
        ok "v4l2-relayd stopped"
    fi

    # 2. Unload module
    if lsmod | grep -q v4l2loopback; then
        modprobe -r v4l2loopback 2>/dev/null || true
        ok "v4l2loopback unloaded"
    fi

    # 3. Borrar archivos instalados por el script
    rm -f "$MODPROBE_CONF" "$MODULES_LOAD_CONF" "$SIGN_SERVICE" "$SIGN_SCRIPT"
    rm -f "$V4L2_RELAYD_CONF"
    systemctl daemon-reload
    ok "Config files removed"

    # 4. Remove MOK key from firmware (if it exists and is enrolled)
    if [[ -f "$MOK_DER" ]]; then
        if key_enrolled; then
            echo
            info "Queueing MOK key deletion from firmware..."
            echo "  You will be prompted for a temporary password."
            echo "  Write it down — you will enter it at the MOK Manager screen after reboot."
            echo
            mokutil --delete "$MOK_DER"
            echo
            echo "  ┌─────────────────────────────────────────────────────────┐"
            echo "  │  REBOOT REQUIRED — follow these steps at the blue screen│"
            echo "  │                                                         │"
            echo "  │    1.  Delete MOK                                       │"
            echo "  │    2.  Continue                                         │"
            echo "  │    3.  Yes                                              │"
            echo "  │    4.  Enter the password you just created              │"
            echo "  │    5.  Reboot                                           │"
            echo "  │                                                         │"
            echo "  │  The key will be removed from firmware on next reboot. │"
            echo "  └─────────────────────────────────────────────────────────┘"
            echo
        else
            info "MOK key exists on disk but is not enrolled in firmware — skipping mokutil"
        fi
    else
        info "No MOK key found on disk"
    fi

    # 5. Borrar directorio de estado (claves y phase file)
    local mok_was_enrolled=false
    key_enrolled && mok_was_enrolled=true || true
    rm -rf "$STATE_DIR"
    ok "State directory removed ($STATE_DIR)"

    echo
    echo "  Uninstall complete."
    if $mok_was_enrolled; then
        echo "  Reboot and confirm MOK deletion at the blue screen to finish."
    fi

    echo
    info "Reboot manually to complete the uninstall."
    if $mok_was_enrolled; then
        echo "  At the blue MOK Manager screen, confirm the key deletion."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

# --uninstall flag: removes everything installed by this script and the MOK key from firmware
[[ "${1:-}" == "--uninstall" ]] && uninstall && exit 0

# --phase2 flag: invoked automatically by the post-reboot service
[[ "${1:-}" == "--phase2" ]] && set_phase "2"

echo
echo "┌────────────────────────────────────────────────┐"
echo "│         Intel IPU6 Camera Fix for Ubuntu       │"
echo "│  Questions: Eduardo Ruiz Duarte                 │"
echo "│  toorandom@gmail.com                           │"
echo "└────────────────────────────────────────────────┘"
echo

install_packages

# ── No Secure Boot: single-pass setup ─────────────────────────────────────────
if ! secure_boot_on; then
    section "Secure Boot: disabled"
    configure_boot_loading
    configure_v4l2relayd
    load_and_start
    echo
    echo "  Done. Camera is ready."
    exit 0
fi

info "Secure Boot: enabled"

# ── Secure Boot: phased setup ─────────────────────────────────────────────────
current_phase=$(get_phase)

# ── PHASE 1: Enroll MOK key, schedule phase 2, reboot ────────────────────────
if [[ "$current_phase" == "1" ]]; then
    section "Phase 1 — MOK key enrollment"

    generate_mok_keys

    if key_enrolled; then
        ok "Key already enrolled in firmware — jumping to phase 2"
        set_phase "2"
        exec bash "$0"
    fi

    echo
    info "Enrolling key with MOK..."
    echo "  You will be prompted for a temporary password."
    echo "  Write it down — you will enter it at the MOK Manager screen after reboot."
    echo
    mokutil --import "$MOK_DER"

    set_phase "2"

    echo
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  REBOOT REQUIRED — follow these steps at the blue screen│"
    echo "  │                                                         │"
    echo "  │    1.  Enroll MOK                                       │"
    echo "  │    2.  Continue                                         │"
    echo "  │    3.  Yes                                              │"
    echo "  │    4.  Enter the password you just created              │"
    echo "  │    5.  Reboot                                           │"
    echo "  │                                                         │"
    echo "  │  After reboot, run this script again as root to finish  │"
    echo "  │  setup of camera:                                       │"
    echo "  │      sudo bash $0                                       │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo
    read -rp "  Reboot now? [Y/n]: " ans
    if [[ "${ans:-y}" =~ ^[nN]$ ]]; then
        echo
        info "Reboot postponed. When ready:"
        info "  1. Reboot and complete MOK enrollment at the blue screen"
        info "  2. Run this script again as root: sudo bash ${INSTALLED_SCRIPT}"
        echo
        exit 0
    fi
    reboot

# ── PHASE 2: Sign, configure, load ────────────────────────────────────────────
elif [[ "$current_phase" == "2" ]]; then
    section "Phase 2 — Signing and configuring"

    # Clear the phase file on entry — if something fails, the next run
    # will fall back to phase 1 automatically without manual cleanup.
    rm -f "$PHASE_FILE"

    if ! key_enrolled; then
        echo
        warn "MOK key not found in firmware."
        warn "Did you complete all steps in MOK Manager at boot?"
        warn "To retry from scratch just run: sudo bash $0"
        exit 1
    fi

    sign_module "$(uname -r)"
    configure_boot_loading
    install_signing_service
    configure_v4l2relayd
    load_and_start

    echo
    echo "  Done. Camera is ready and will work after every kernel update."

    # ── Detect camera device and suggest test command ─────────────────────────
    cam_dev=$(grep -rl "$CARD_LABEL" /sys/devices/virtual/video4linux/*/name 2>/dev/null \
              | head -1 | cut -d/ -f6 || echo "")
    if [[ -z "$cam_dev" ]]; then
        cam_dev=$(ls /dev/video* 2>/dev/null | head -1 | grep -oP 'video\d+' || echo "")
    fi

    if [[ -n "$cam_dev" ]]; then
        echo
        echo "  Camera device detected: /dev/${cam_dev}"
        if command -v ffplay &>/dev/null; then
            echo "  Test it with:"
            echo "      ffplay -f v4l2 -i /dev/${cam_dev}"
        else
            echo "  To test the camera, install ffmpeg and run:"
            echo "      sudo apt install ffmpeg"
            echo "      ffplay -f v4l2 -i /dev/${cam_dev}"
        fi
    fi

else
    die "Unknown phase '${current_phase}'. Reset with: sudo rm ${PHASE_FILE}"
fi
