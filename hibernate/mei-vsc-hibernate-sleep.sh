#!/bin/bash
# systemd-sleep hook: after hibernate, force IVSC FW reload via mei_vsc sysfs
# only if the kernel deferred reattach did not already bind the sensor.
# Install to: /usr/lib/systemd/system-sleep/mei-vsc-hibernate
set -u

ov02c10_bound() {
	local d base
	[[ -e /sys/bus/i2c/devices/i2c-OVTI02C1:00/driver ]] && return 0
	for d in /sys/bus/i2c/drivers/ov02c10/*; do
		[[ -d "$d" ]] || continue
		base=$(basename "$d")
		case "$base" in module|uevent|bind|unbind) continue ;; esac
		return 0
	done
	return 1
}

csi_bound() {
	local d base
	[[ -d /sys/bus/mei/drivers/ivsc_csi ]] || return 1
	for d in /sys/bus/mei/drivers/ivsc_csi/*; do
		base=$(basename "$d")
		case "$base" in module|uevent|bind|unbind) continue ;; esac
		[[ -e "$d" ]] || continue
		return 0
	done
	return 1
}

phase=${1:-}
action=${2:-}

case "$phase" in
pre)
	;;
post)
	# La ruta de la tapa es suspend-then-hibernate: systemd pasa ESA acción,
	# no "hibernate", así que el guard antiguo dejaba el hook inerte.
	case "$action" in hibernate|suspend-then-hibernate) ;; *) exit 0 ;; esac

	# PAM Howdy skip waits on this stamp (lock screen after S4).
	date +%s >/run/howdy-wait-hibernate 2>/dev/null || true

	FW=/sys/devices/platform/intel_vsc/fw_reload

	# Poll — do not sleep 12s first; lock-screen Howdy is waiting on the stamp.
	# After v1.16 the client is a swnode i2c device, not i2c-OVTI02C1:00.
	i=0
	while (( i < 20 )); do
		if ov02c10_bound; then
			logger -t mei-vsc-hibernate "ov02c10 bound after ${i}s; restart relay, skip fw_reload"
			systemctl try-restart 'v4l2-relayd@*' 2>/dev/null || true
			exit 0
		fi
		if csi_bound && [[ $i -ge 12 ]]; then
			# CSI up but sensor still missing — fall through to fw_reload
			break
		fi
		i=$((i + 1))
		sleep 1
	done

	if ov02c10_bound; then
		logger -t mei-vsc-hibernate "ov02c10 bound; skip fw_reload"
		systemctl try-restart 'v4l2-relayd@*' 2>/dev/null || true
		exit 0
	fi

	i=0
	while (( i < 5 )); do
		if ov02c10_bound; then
			logger -t mei-vsc-hibernate "bound during fw_reload wait; skip"
			systemctl try-restart 'v4l2-relayd@*' 2>/dev/null || true
			exit 0
		fi
		if [[ -w "$FW" ]]; then
			if echo 1 >"$FW" 2>/tmp/mei-vsc-fw-reload.err; then
				logger -t mei-vsc-hibernate "wrote $FW (try $((i+1)))"
				sleep 3
				systemctl try-restart 'v4l2-relayd@*' 2>/dev/null || true
				exit 0
			fi
			logger -t mei-vsc-hibernate "write $FW failed: $(cat /tmp/mei-vsc-fw-reload.err 2>/dev/null)"
		else
			logger -t mei-vsc-hibernate "$FW missing/not writable (try $((i+1)))"
		fi
		i=$((i + 1))
		sleep 2
	done
	logger -t mei-vsc-hibernate "gave up fw_reload after hibernate"
	systemctl try-restart 'v4l2-relayd@*' 2>/dev/null || true
	;;
esac
exit 0
