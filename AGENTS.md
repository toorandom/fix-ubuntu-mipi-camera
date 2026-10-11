# Instructions for coding agents

This repo fixes Intel IPU6 MIPI cameras on Linux. If a human handed you this repo, they
most likely have a broken camera. Work the runbook below rather than reading the whole
source first.

Read `README.md` for the why, `hibernate/README.md` for the hibernation internals. The
same procedure is packaged as a Claude Code skill in `skills/ipu6-camera/`.

## 0. Establish which of the two problems this is

They are independent and have different fixes. Do not conflate them.

```bash
ls /dev/ipu-psys0 2>/dev/null && echo "PSYS present" || echo "PSYS MISSING"
grep -rl 'Intel MIPI Camera' /sys/devices/virtual/video4linux/*/name 2>/dev/null \
  | head -1 | cut -d/ -f6
journalctl -b -k --no-pager | grep -cE 'hibernation exit'
```

| The human says | Problem | Script |
|---|---|---|
| never worked / broke after a kernel upgrade / Zoom sees nothing | pipeline | `ipu6-camera-fix.sh` |
| works until I hibernate / hangs when I close the lid | hibernation | `ipu6-hibernate-fix.sh` |
| frozen on one frame | CSI-2 link, not the stack | restart `v4l2-relayd@default` |
| image upside down | sensor mounting | orientation service, §4 |

Both scripts take `--status` and change nothing. **Always run `--status` first** and show
the human the output before proposing anything.

## 1. Hard rules

Violating these breaks the human's machine or wastes an hour. Each one was learned the
hard way.

- **Never `systemctl restart systemd-logind`** with a graphical session open — it closes
  their session. Use `systemctl reload systemd-logind`. Note that editing
  `logind.conf.d/` does nothing until you reload; verify what is actually live with
  `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager HandleLidSwitch`.
- **Never use `rtcwake` to test sleep.** It bypasses `/usr/lib/systemd/system-sleep/`
  entirely — the hooks you are testing — and can wedge the MEI stack
  (`mei mei1: device disabled`), which then needs a **full power off**, since a warm
  reboot does not reset the VSC firmware.
- **Never hot-reload `intel_skl_int3472_discrete`.** It takes the touchpad down with it.
- **Never install `ov02c10` by hand into `/lib/modules/*/updates/`.** It must go through
  DKMS or the next kernel silently drops it.
- **Never "fix" the reference leaks** in `ipu_bridge_reattach_sensor_swnodes()`,
  `ipu_bridge_sensor_bound()` or `ipu_bridge_destroy_sensor_i2c_clients()`. They are
  leaks rather than underflows, and they are what keeps the sensor's software node alive
  against the core bug described in `hibernate/README.md`.
- **Never disable a sleep hook by renaming it `.disabled`.** `systemd-sleep` runs every
  executable file in that directory regardless of extension. Move it out, or clear `+x`.
- **Do not reboot or power off without asking.** Several steps need it; let the human
  choose when.

## 2. Reading evidence correctly

- **`dmesg -T` lies after hibernation.** It derives wall-clock from boot time and drifts
  by however long the machine was off. Use `journalctl`, which carries a real clock.
  Do not conclude "it never hibernated" from `dmesg -T`.
- **A hang at `Freezing user space processes` tells you nothing about where it hung.**
  journald is frozen at that same step, so the log always ends on that line. Absence of
  later messages is not evidence.
- **`cmd | grep -q ...` under `set -o pipefail` returns the opposite of the truth.**
  grep exits at the first match, the producer dies of SIGPIPE (141), and pipefail
  propagates it. Capture to a variable and filter with `<<<`.
- **The `/dev/videoN` number changes between boots.** Never hardcode `video0`; find it by
  label (the command in §0).
- **Judging the camera by PNG file size is unreliable.** A smooth scene compresses to a
  few KB and looks like a black frame. Measure brightness instead:
  ```bash
  ffmpeg -loglevel error -f v4l2 -i /dev/videoN -t 5 \
    -vf "format=gray,signalstats,metadata=print" -f null - 2>&1 | grep YAVG | tail -2
  ```
  Also: the **first** capture after the pipeline has been idle returns cached black
  frames. Do a throwaway capture, then the real one.
- The Intel HAL emits black frames for the first ~2 seconds while auto-exposure
  converges. Capture for seconds, not frames.

## 3. Fixing it

```bash
sudo bash ipu6-hibernate-fix.sh --status     # always first
sudo apt install linux-headers-$(uname -r)   # the usual missing piece
sudo bash ipu6-hibernate-fix.sh              # install
```

All three modules (`ipu-bridge`, `mei-vsc`, `ov02c10`) must end up under
`updates/dkms/`, and `modinfo ov02c10` must list `alias: i2c:ov02c10`. If either is not
true, the camera will not come back from hibernation.

If the DKMS build fails because a newer kernel changed an API: tell the human they can
boot the previous kernel from GRUB's "Advanced options" meanwhile (DKMS leaves the old
kernel's modules in place), then diff `hibernate/ipu-bridge/ipu-bridge.c` against the
`ipu-bridge.c` of the matching `linux-source` and re-apply the overlay's changes onto the
new file. Back up before editing; keep `*.pre-*` copies.

Secure Boot: DKMS signs with the MOK in `/var/lib/shim-signed/mok/`. If the key is not
enrolled yet, enrolling it needs a reboot and the human typing a password at the blue MOK
Manager screen. You cannot do that part.

## 4. Orientation

If the image is upside down, the flips are not set on the sensor subdev. The installed
service handles it; to apply by hand:

```bash
SUB=$(for d in /sys/class/video4linux/v4l-subdev*; do \
        grep -q '^ov02c10' "$d/name" 2>/dev/null && basename $d && break; done)
sudo systemctl start ipu6-sensor-orientation@$SUB.service
v4l2-ctl -d /dev/$SUB --list-ctrls | grep flip      # both must read value=1
```

Setting the control once is not enough: `ipu_bridge` re-probes right after the udev event
and that bind resets the sensor registers. The service sets and re-verifies in a loop.

## 5. Verifying — the part agents get wrong

**You cannot test this yourself.** The only valid test needs the human to close the lid.

- A plain `systemctl suspend` **does not reproduce the hibernation bug**: on a clean boot
  it does not recreate `mei-csi` at all. Proving the fix with one is proving nothing.
- `rtcwake` is not a substitute. See §1.

Ask the human to: close the lid, leave it closed long enough to hibernate
(`HibernateDelaySec`, plus about a minute to write the image), open it, and say when
they are back. **Then ask them to do it a second time** — the historical failure appeared
on the *second* cycle, not the first. Declaring success after one cycle is wrong.

After each resume:

```bash
sudo ipu6-camera-healthcheck
journalctl -b -k -o short-precise | grep -E 'hibernation (entry|exit)|Freezing user'
journalctl -b -k | grep -E 'attached INTC10CF|no INTC10CF-N|refcount_t:'
```

Healthy: `hibernation exit` present, `attached INTC10CF-N` once per resume, and **no**
`no INTC10CF-N swnode` and **no** `refcount_t:` lines. If the machine needed the power
button, say so plainly rather than reading success into a partial log.

## 6. Rolling back

```bash
sudo bash ipu6-hibernate-fix.sh --uninstall
sudo reboot
```

DKMS restores the distro modules it archived. Offer this early if the human seems to be
losing working time.

## Licensing when editing

`hibernate/` is **GPL-2.0**, derived from kernel source and from a third-party overlay;
the rest of the repo is MIT. Keep each file's SPDX header. Do not move code between the
two without accounting for the licence.
