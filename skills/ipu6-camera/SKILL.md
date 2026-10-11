---
name: ipu6-camera
description: Diagnose and repair an Intel IPU6 MIPI camera (ov02c10 / ov02e10 and friends), especially after a kernel upgrade or when hibernation leaves it dead. Use when the camera stops working, Zoom or a browser sees no image, the picture is frozen or upside down, or the machine hangs on suspend or hibernate.
---

# Intel IPU6 MIPI camera

Repo: https://github.com/toorandom/fix-ubuntu-mipi-camera
Assume the clone is at `$REPO`; the hibernation overlay lives in `$REPO/hibernate`
(DKMS package `mei-vsc-hibernate`).

Two separate problems, two separate scripts. Work out which one it is first.

| Symptom | Script |
|---|---|
| Camera never worked, or broke after a kernel upgrade | `ipu6-camera-fix.sh` |
| Camera dies only after hibernation, or hibernating hangs | `ipu6-hibernate-fix.sh` |

## Triage first

```bash
ls /dev/ipu-psys0                              # Intel HAL needs this
sudo ipu6-camera-healthcheck                   # hibernation stack, running kernel
sudo bash $REPO/ipu6-camera-fix.sh --status
sudo bash $REPO/ipu6-hibernate-fix.sh --status
```

Three things must be true for hibernation to work:

| Check | Correct value | If not |
|---|---|---|
| `dkms status mei-vsc-hibernate` | `installed` for the running kernel | reinstall (below) |
| `modinfo ov02c10` | path under `updates/dkms/` **and** `alias: i2c:ov02c10` | wrong module is loaded |
| `ls /dev/ipu-psys0` | exists | PSYS did not probe; that is the other script's problem |

## After a kernel upgrade

DKMS rebuilds all three modules by itself (`AUTOINSTALL="yes"`): `ipu-bridge`, `mei-vsc`,
`ov02c10`. If `dkms status` does not list the new kernel, the usual cause is missing
headers:

```bash
sudo apt install linux-headers-$(uname -r)
cd $REPO && sudo bash ipu6-hibernate-fix.sh
sudo reboot
```

If the build genuinely fails because the new kernel changed an API, **do not improvise**.
Boot the previous kernel from GRUB's "Advanced options" — DKMS leaves the old kernel's
modules in place, so everything still works there — then diff
`hibernate/ipu-bridge/ipu-bridge.c` against the `ipu-bridge.c` of the matching
`linux-source` and re-apply the overlay's changes on top of the new file. Back up before
editing.

`ov02c10` is the piece that silently breaks upgrades: built by hand it disappears with
the old kernel, the stock one loads without `i2c_device_id`, and the post-S4 i2c client
binds to nothing. It belongs in the DKMS package, never in `updates/` by hand.

## Image upside down

Some sensors are mounted at 180° and nothing applies that automatically. The flips live
on the sensor subdev, whose number changes on every boot and every post-S4 re-probe, so
a udev rule triggers `ipu6-sensor-orientation@.service` on the subdev's `add` event.

The script sets the flips **and verifies them in a loop** on purpose: `ipu_bridge` does a
deferred re-probe right after the udev event (`ov02c10 bound after delay`) and that bind
reinitialises the sensor registers, wiping a single-shot write.

```bash
SUB=$(for d in /sys/class/video4linux/v4l-subdev*; do \
        grep -q '^ov02c10' "$d/name" && basename $d && break; done)
v4l2-ctl -d /dev/$SUB --list-ctrls | grep flip     # both should read value=1
sudo systemctl start ipu6-sensor-orientation@$SUB.service
```

## Image frozen on one frame

That is the CSI-2 link's `Frame sync error`, not a broken stack. `v4l2loopback` keeps
serving its last cached frame, so apps show a still image rather than an error.

```bash
sudo dmesg | grep 'Frame sync error'
sudo systemctl restart v4l2-relayd@default.service
```

## Hangs on suspend or hibernate

**Check the sleep hooks first.** `systemd-sleep` runs **every executable file** in
`/usr/lib/systemd/system-sleep/`, **regardless of its extension**: renaming one to
`.disabled` does not disable it.

```bash
ls -la /usr/lib/systemd/system-sleep/     # look at the +x bit, not the name
```

Only `mei-vsc-hibernate` should be there (besides distro ones such as `hdparm`,
`sysstat.sleep`, `unattended-upgrades`). A leftover `50-ipu6-camera` will hang
hibernation: it does `unbind`/`bind` of vsc-tp and the IPU6 PCI device over ~20s,
finishing right before the freeze with deferred probe still in flight. Move it out of the
directory, or clear its `+x`.

Two traps when reading the logs:

- **A hang at `Freezing user space processes` does not mean the kernel died there.**
  journald is one of the processes frozen at that step, so the log always stops on that
  line, hang or no hang. Absence of later messages proves nothing.
- **`dmesg -T` lies after hibernation** — it derives dates from boot time and drifts. Use
  `journalctl`, which carries a real clock.

## Testing it honestly

A plain `systemctl suspend` proves nothing: on a clean boot it does not recreate
`mei-csi` at all. `rtcwake` is worse — it bypasses the `systemd-sleep` hooks entirely and
can wedge the MEI stack (`mei mei1: device disabled`), which then needs a **full power
off**, because a warm reboot does not reset the VSC firmware.

The only valid test is the real one: close the lid, let it hibernate, open it, verify.
**And do it twice** — the historical failure appeared on the *second* cycle, not the
first.

```bash
journalctl -b -k -o short-precise | grep -E 'hibernation (entry|exit)|Freezing user'
journalctl -b -k | grep -E 'attached INTC10CF|no INTC10CF-N|refcount_t:'
```

`no INTC10CF-N swnode` or any `refcount_t:` line means the IVSC software node was freed.

## The two bugs this fixes

1. **Unbalanced refcount on the IVSC software node.**
   `software_node_notify_remove()` does an **unconditional** `kobject_put()` — outside
   the `if (swnode->managed)` block — paired with the `kobject_get()` that
   `software_node_notify()` does at `device_add()`. The fwnode is attached to `mei-csi`
   *after* the MEI bus added it, so the get never happens but the put always does.
   `INTC10CF-N` starts at 3 (itself plus its two port children) and the MEI bus recreates
   `mei-csi` on every resume, so the third resume frees it and `isys` walks into freed
   memory. Fixed by holding a reference in `ipu_bridge_instantiate_ivsc()` and
   `ipu_bridge_attach_swnode()`. The first is **upstream code**: a real upstream bug, see
   `hibernate/patches/0001-ipu-bridge-hold-a-reference-on-the-IVSC-swnode.patch`.
2. **The legacy sleep hook** described above. Independent of the first — fixing the
   refcount alone left the machine still hanging.

Do **not** "fix" the reference leaks on the sensor side
(`ipu_bridge_reattach_sensor_swnodes()`, `ipu_bridge_sensor_bound()`,
`ipu_bridge_destroy_sensor_i2c_clients()`): those are leaks rather than underflows, and
they are what keeps the sensor's own node alive against the same core bug.

## Rolling back

```bash
sudo bash $REPO/ipu6-hibernate-fix.sh --uninstall
sudo reboot
```
