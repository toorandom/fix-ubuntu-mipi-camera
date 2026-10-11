#!/usr/bin/env bash
# ipu6-hibernate-fix.sh — make an Intel IPU6 MIPI camera survive hibernation.
#
# Companion to ipu6-camera-fix.sh, which gets the camera working in the first
# place. This one is about what happens after you close the lid.
#
# WHAT IT FIXES (see hibernate/README.md for the full story)
#
#   1. The IVSC firmware is lost when the machine powers off, and nothing
#      reloads it:          vsc-tp: wakeup firmware failed ret: -110
#   2. mei-csi is recreated without its fwnode, so the video graph is gone:
#                           ivsc_csi: mei-csi probed without device fwnode!
#   3. The sensor's i2c client is an ACPI one that cannot be recreated after
#      S4. A non-ACPI client whose primary fwnode is the software node is
#      instantiated instead, and the sensor is given an i2c_device_id so it
#      matches:             ov02c10: failed to find sensor: -5
#   4. An unbalanced refcount on the IVSC software node. This is the one that
#      hung the machine on the SECOND hibernation; the first always worked.
#      software_node_notify_remove() does an unconditional kobject_put(), but
#      the matching get only happens at device_add() time -- and the fwnode is
#      attached to mei-csi after it is added. The MEI bus recreates mei-csi on
#      every resume, so the node loses a reference per cycle and is freed on
#      the third:            refcount_t: addition on 0; use-after-free
#      See hibernate/patches/0001-ipu-bridge-hold-a-reference-on-the-IVSC-swnode.patch
#      -- that one is an upstream bug, worth sending up.
#   5. A legacy sleep hook doing unbind/bind of vsc-tp and the IPU6 PCI device
#      right before the freeze, hanging it. Note that systemd-sleep runs EVERY
#      executable file in /usr/lib/systemd/system-sleep/ regardless of its
#      extension, so renaming one to ".disabled" does not disable it.
#   6. The ov02c10 is mounted at 180 degrees and nothing applies that.
#
# Author: Eduardo Ruiz Duarte <toorandom@gmail.com>
# Tested on: Dell XPS 13 9340, ov02c10-uf, Ubuntu 26.04.1, kernel 7.0.0-1015-oem

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$SRC/hibernate"
# /lib/systemd/system-sleep suele ser un enlace a /usr/lib/...; deduplicar
# por ruta real o se lista (y se procesa) todo dos veces.
LEGACY_HOOK_DIRS=()
for _d in /usr/lib/systemd/system-sleep /lib/systemd/system-sleep; do
    [[ -d "$_d" ]] || continue
    _r=$(readlink -f "$_d")
    [[ " ${LEGACY_HOOK_DIRS[*]-} " == *" $_r "* ]] || LEGACY_HOOK_DIRS+=("$_r")
done
RETIRED=/root/hooks-retirados
DELAY="${IPU6_HIBERNATE_DELAY:-10min}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  [\033[32mok\033[0m] %s\n' "$*"; }
warn() { printf '  [\033[33m!!\033[0m] %s\n' "$*"; }
die()  { printf '  [\033[31mxx\033[0m] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || exec sudo -E "$0" "$@"

case "${1:-}" in
  --status) MODE=status ;;
  --uninstall) MODE=uninstall ;;
  ""|--install) MODE=install ;;
  *) echo "Uso: $0 [--install|--status|--uninstall]"; exit 2 ;;
esac

KVER=$(uname -r)

# ---------------------------------------------------------------- status ----
status() {
    say "Kernel y paquete"
    echo "  kernel            : $KVER"
    local ds; ds=$(dkms status mei-vsc-hibernate 2>/dev/null)
    if grep -q "$KVER" <<<"$ds"; then ok "DKMS: ${ds//$'\n'/ ; }"
    else warn "DKMS NO instalado para $KVER -- el overlay no está activo"; fi

    say "Módulos (los tres deben venir de updates/dkms)"
    local m p
    for m in ipu-bridge mei-vsc ov02c10; do
        p=$(modinfo -n "$m" 2>/dev/null)
        if [[ "$p" == */updates/dkms/* ]]; then ok "$m -> $p"
        else warn "$m -> ${p:-ausente}  (no lo gestiona DKMS)"; fi
    done
    if modinfo ov02c10 2>/dev/null | grep -q 'alias:.*i2c:ov02c10'; then
        ok "ov02c10 expone i2c:ov02c10"
    else
        warn "ov02c10 SIN i2c:ov02c10 -- el cliente post-S4 no enlazará"
    fi

    say "Hooks de sleep (cuenta el bit +x, no la extensión)"
    local d f
    for d in "${LEGACY_HOOK_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*; do
            [[ -x "$f" ]] || continue
            case "$(basename "$f")" in
                50-ipu6-camera*) warn "$f  <-- EN CONFLICTO, cuelga la hibernación" ;;
                mei-vsc-hibernate) ok "$f" ;;
                *) echo "       $f" ;;
            esac
        done
    done

    say "Suspensión"
    grep -hE '^(Hibernate|Suspend)' /etc/systemd/sleep.conf.d/*.conf 2>/dev/null \
        | sed 's/^/  /' || warn "sin drop-ins en sleep.conf.d"
    local p2
    for p2 in HandleLidSwitch HandleLidSwitchExternalPower; do
        echo "  $p2 = $(busctl get-property org.freedesktop.login1 \
            /org/freedesktop/login1 org.freedesktop.login1.Manager "$p2" 2>/dev/null)"
    done

    say "Orientación del sensor"
    local sub=""
    for d in /sys/class/video4linux/v4l-subdev*; do
        [[ -r "$d/name" ]] && grep -q '^ov02c10' "$d/name" 2>/dev/null \
            && { sub=$(basename "$d"); break; }
    done
    if [[ -n "$sub" ]]; then
        if v4l2-ctl -d "/dev/$sub" --list-ctrls 2>/dev/null \
             | grep -q 'horizontal_flip.*value=1'; then ok "flips puestos en /dev/$sub"
        else warn "flips sin poner en /dev/$sub -- la imagen saldrá del revés"; fi
    else
        warn "no hay subdev del sensor (¿cámara caída?)"
    fi

    say "Historial de esta sesión"
    local probes attach lost rc
    probes=$(journalctl -b -k --no-pager 2>/dev/null | grep -c 'hardware version 6')
    attach=$(journalctl -b -k --no-pager 2>/dev/null | grep -c 'attached INTC10CF')
    lost=$(journalctl -b -k --no-pager 2>/dev/null | grep -c 'no INTC10CF-N swnode')
    rc=$(journalctl -b -k --no-pager 2>/dev/null | grep -c 'refcount_t:')
    echo "  probes de intel-ipu6 : $probes"
    echo "  enganches del IVSC   : $attach"
    (( lost == 0 )) && ok "el nodo IVSC nunca se perdió" \
                    || warn "el nodo IVSC se perdió $lost veces"
    (( rc == 0 ))   && ok "sin avisos de refcount" \
                    || warn "$rc avisos de refcount -- hay un use-after-free"
}

# --------------------------------------------------------------- install ----
install_all() {
    [[ -d "$OVERLAY" ]] || die "falta $OVERLAY (¿clonaste el repo entero?)"
    command -v dkms >/dev/null || die "falta dkms: apt install dkms"
    [[ -d "/lib/modules/$KVER/build" ]] \
        || die "faltan las cabeceras: apt install linux-headers-$KVER"

    say "Retirando hooks de sleep en conflicto"
    # Renombrarlos no basta: systemd-sleep ejecuta todo lo que tenga +x.
    mkdir -p "$RETIRED"
    local d f moved=0
    for d in "${LEGACY_HOOK_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/50-ipu6-camera*; do
            [[ -e "$f" ]] || continue
            mv -v "$f" "$RETIRED/" && moved=1
        done
    done
    (( moved )) && ok "retirados a $RETIRED" || ok "no había ninguno"

    say "Compilando e instalando el overlay DKMS"
    ( cd "$OVERLAY" && ./install.sh ) || die "falló install.sh del overlay"
    dkms status mei-vsc-hibernate | grep -q "$KVER" \
        || die "DKMS no quedó instalado para $KVER"
    ok "overlay instalado"

    say "Orientación del sensor (montado a 180°)"
    install -m 0755 /dev/stdin /usr/local/sbin/ipu6-sensor-orientation <<'ORIENT'
#!/bin/bash
# Pone los flips del sensor Y LOS VERIFICA en bucle: ipu_bridge hace un
# re-probe diferido justo después del evento udev ("ov02c10 bound after
# delay") y ese bind reinicializa los registros, borrando una escritura única.
name="${1:-}"; [ -n "$name" ] || exit 0
dev="/dev/$name"
flips_ok() {
    local out; out=$(v4l2-ctl -d "$dev" --list-ctrls 2>/dev/null) || return 1
    grep -q 'horizontal_flip.*value=1' <<<"$out" &&
    grep -q 'vertical_flip.*value=1'   <<<"$out"
}
for _ in $(seq 1 25); do
    [ -e "$dev" ] && v4l2-ctl -d "$dev" --list-ctrls 2>/dev/null \
        | grep -q horizontal_flip && break
    sleep 0.2
done
[ -e "$dev" ] || exit 0
estable=0
for _ in $(seq 1 40); do
    flips_ok || { timeout 5 v4l2-ctl -d "$dev" \
                    --set-ctrl=horizontal_flip=1,vertical_flip=1 2>/dev/null
                  estable=0; }
    if flips_ok; then
        estable=$((estable + 1))
        [ "$estable" -ge 3 ] && exit 0
    fi
    sleep 0.5
done
exit 0
ORIENT

    cat > /etc/systemd/system/ipu6-sensor-orientation@.service <<'UNIT'
[Unit]
Description=Fix the 180-degree mounting of the ov02c10 sensor on %i

[Service]
Type=oneshot
TimeoutStartSec=40
ExecStart=/usr/local/sbin/ipu6-sensor-orientation %i
UNIT

    # Por servicio y no por RUN+=: udev mata los RUN largos, y el nodo /dev
    # todavía no existe cuando se procesa el evento.
    cat > /etc/udev/rules.d/71-ipu6-sensor-orientation.rules <<'RULE'
ACTION=="add", SUBSYSTEM=="video4linux", KERNEL=="v4l-subdev*", \
  ATTR{name}=="ov02c10*", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="ipu6-sensor-orientation@%k.service"
RULE
    systemctl daemon-reload
    udevadm control --reload-rules
    ok "regla udev + servicio instalados"

    say "Suspensión: tapa = suspend-then-hibernate"
    mkdir -p /etc/systemd/logind.conf.d /etc/systemd/sleep.conf.d
    cat > /etc/systemd/logind.conf.d/10-lid-suspend-then-hibernate.conf <<'CONF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
CONF
    cat > /etc/systemd/sleep.conf.d/10-hibernate-delay.conf <<CONF
[Sleep]
HibernateDelaySec=$DELAY
HibernateOnACPower=yes
CONF
    # Este firmware es Modern Standby (S0ix) y NO implementa ACPI S4: con
    # HibernateMode=platform la hibernación despierta al instante y aborta sin
    # escribir la imagen. 'shutdown' escribe y apaga de forma normal.
    cat > /etc/systemd/sleep.conf.d/20-hibernate-mode.conf <<'CONF'
[Sleep]
HibernateMode=shutdown
CONF
    # reload, NUNCA restart: un restart cierra la sesión gráfica abierta.
    systemctl reload systemd-logind 2>/dev/null || true
    ok "tapa configurada (hiberna a los $DELAY)"

    say "Listo"
    cat <<'EOF'
  Reinicia, y después prueba así -- y solo así:

    cerrar la tapa -> esperar a que hiberne -> abrir -> verificar
    Y REPETIRLO: el fallo histórico salía en el SEGUNDO ciclo, no en el primero.

  Un "systemctl suspend" corriente no prueba nada (en un arranque limpio no
  recrea mei-csi), y rtcwake tampoco: salta los hooks de systemd-sleep y deja
  el MEI atascado, obligando a un apagado completo.

    sudo ipu6-hibernate-fix.sh --status
EOF
}

# ------------------------------------------------------------- uninstall ----
uninstall_all() {
    say "Quitando el overlay DKMS"
    local v
    while read -r v; do
        [[ -n "$v" ]] && dkms remove "mei-vsc-hibernate/$v" --all 2>&1 | sed 's/^/  /'
    done < <(dkms status 2>/dev/null \
             | sed -n 's|^mei-vsc-hibernate[/,] *\([0-9.]\+\).*|\1|p' | sort -u)
    rm -rf /usr/src/mei-vsc-hibernate-* 2>/dev/null

    say "Quitando hook, regla y servicio"
    rm -fv /usr/lib/systemd/system-sleep/mei-vsc-hibernate \
           /lib/systemd/system-sleep/mei-vsc-hibernate \
           /etc/udev/rules.d/71-ipu6-sensor-orientation.rules \
           /etc/systemd/system/ipu6-sensor-orientation@.service \
           /usr/local/sbin/ipu6-sensor-orientation 2>/dev/null
    systemctl daemon-reload; udevadm control --reload-rules
    depmod -a
    ok "quitado. La configuración de la tapa se deja como está; bórrala a mano"
    echo "     si la quieres fuera: /etc/systemd/{logind,sleep}.conf.d/*hibernate*"
}

case "$MODE" in
    status)    status ;;
    install)   install_all ;;
    uninstall) uninstall_all ;;
esac
