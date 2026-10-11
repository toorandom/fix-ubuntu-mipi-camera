# fix-ubuntu-mipi-camera

Fix for Intel IPU6 MIPI cameras (`ov02c10`, `ov08x40`, etc.) on **Ubuntu 26.04 LTS**
(also works on 22.04 / 24.04), on any kernel — including the ones that broke it.

Many modern laptops with Intel 12th/13th/14th gen CPUs have a MIPI camera wired through
the Intel IPU6 ISP. These cameras do not show up as standard V4L2 devices, so nothing
that expects `/dev/videoN` can use them out of the box.

**Author:** Eduardo Ruiz Duarte <toorandom@gmail.com>

---

## The problem nobody explains

If your camera stopped working after a kernel upgrade, this is almost certainly why.

Intel's camera HAL (`libcamhal`, driven by the `icamerasrc` GStreamer element) needs the
PSYS device node **`/dev/ipu-psys0`**. PSYS is the hardware ISP interface, and it only
ever lived in Intel's *out-of-tree* IPU6 driver.

Since **kernel 6.10** the IPU6 driver is *in-tree*, and it ships ISYS only. When the
out-of-tree `intel-ipu6-psys` module does not match the in-tree `intel-ipu6`, it loads,
never probes, and `/dev/ipu-psys0` never appears.

What makes this so confusing is that **everything else still looks perfectly healthy**:

- `v4l2loopback` loads fine
- `v4l2-relayd` is `active (running)`
- `/dev/video0` exists and apps list the camera
- the LED may even turn on

…and not a single frame is ever produced. The only visible clue is buried in the journal:

```bash
journalctl -u v4l2-relayd@default.service -b | grep CamHAL
```
```
CamHAL[ERR] Failed to open PSYS, error: No such file or directory
CamHAL[ERR] Failed to create PGs for executor: ipu6_lb_video_bayer
CamHAL[ERR] failed to config streams.
```

This is why checking module signatures, reinstalling packages or regenerating MOK keys
never helps: none of those are the problem.

As a bonus, an orphaned `intel-ipu6-psys` does not merely fail — it also NULL-derefs the
kernel in `isys_runtime_pm_suspend`, which can take your suspend path down with it.

**One command tells you whether your kernel can use the hardware ISP at all:**

```bash
ls /dev/ipu-psys0
```

---

## Two pipelines, picked automatically

The script does not assume either path works. It tries, captures real frames, and keeps
whichever actually delivers.

| Pipeline | Image quality | Survives kernel upgrades? | Needs |
|---|---|---|---|
| **`icamerasrc`** — Intel HAL, hardware ISP | Best: correct exposure and white balance | ❌ depends on the out-of-tree PSYS module | `/dev/ipu-psys0` |
| **`libcamerasrc`** — libcamera + software ISP | Greener and darker without a sensor tuning file | ✅ in-tree driver only | libcamera ≥ 0.3 |

Both are fed into **`v4l2loopback`**, so the camera always ends up as a plain
`/dev/videoN`. That matters: it works in *everything*, including **Zoom**, which does not
speak PipeWire camera.

The trick that makes this cheap is that `v4l2-relayd` accepts any GStreamer source, so
switching pipelines is a single line of config.

---

## Quick start

```bash
sudo bash ipu6-camera-fix.sh
```

That is it, if Secure Boot is off. The script installs the packages, configures
`v4l2loopback`, picks the best working pipeline, **verifies it by capturing actual
frames**, and installs a hook so kernel upgrades do not silently break it again.

```bash
sudo bash ipu6-camera-fix.sh --status      # diagnose, change nothing
sudo bash ipu6-camera-fix.sh --libcamera   # force the libcamera pipeline
sudo bash ipu6-camera-fix.sh --hal         # force the Intel HAL pipeline
sudo bash ipu6-camera-fix.sh --uninstall   # remove everything
```

`--status` prints the full picture, including whether frames are actually flowing:

```
  Kernel            : 7.0.0-38-generic
  Ubuntu            : Ubuntu 26.04.1 LTS
  /dev/ipu-psys0    : present (HAL usable)
  icamerasrc        : present
  libcamerasrc      : present
  v4l2loopback      : loaded
  v4l2-relayd       : active
  Active pipeline   : icamerasrc buffer-count=7
  Camera node       : /dev/video0
  [✓] Camera is delivering frames
```

### With Secure Boot (two phases)

Secure Boot requires `v4l2loopback` to be signed with a key your firmware trusts.

**Phase 1** — run the script. It generates an RSA-2048 key in
`/var/lib/ipu6-camera-fix/`, registers it with `mokutil --import`, and asks you for a
temporary password. **Write it down.** Then reboot.

At the blue **MOK Manager** screen:

```
Enroll MOK → Continue → Yes → enter the password → Reboot
```

**Phase 2** — run the script again. It verifies the key, signs the module, installs a
boot service that re-signs it on every kernel update, and brings the camera up.

---

## Testing it

```bash
ffplay -f v4l2 -i /dev/video0
```

Or <https://webcammictest.com/>. **Do not test with Cheese** — it does not work with
this setup and will make you think the fix failed.

> Note: the Intel HAL emits **black frames for the first couple of seconds** while
> auto-exposure converges. If you grab a single frame you will get a black image and
> conclude it is broken. The script discards the first 60 frames for exactly this reason.

---

## Hibernation

A separate problem with a separate fix, in `ipu6-hibernate-fix.sh`.

Hibernation powers the machine off. The IVSC (Intel Visual Sensing Controller) loses its
firmware, nothing reloads it, and the camera never comes back:

```
vsc-tp spi-INTC10D0:00: wakeup firmware failed ret: -110
ivsc_csi ...: mei-csi probed without device fwnode!
ov02c10 ...: failed to find sensor: -5
```

Worse, on this hardware the **second** hibernation used to hang the machine outright —
black screen, power button, no log. The first one always worked, which is what made it so
confusing.

That turned out to be **two independent bugs**, one in the kernel and one in userspace,
and they have to be kept apart because each needs a different fix:

| | Symptom | Where | Fixed by |
|---|---|---|---|
| **A** | crash on **resume**: `refcount_t: addition on 0` in `isys_probe`, IVSC node freed | kernel | the patch below |
| **B** | hang on the way **into** S4, stuck at `Freezing user space processes` | userspace | removing a legacy sleep hook |

Fixing A alone was not enough: the resume that used to die went through clean, and the
machine still hung — that was B, found afterwards. The patch does **not** fix B.

```bash
sudo bash ipu6-hibernate-fix.sh            # install
sudo bash ipu6-hibernate-fix.sh --status   # diagnose, change nothing
sudo bash ipu6-hibernate-fix.sh --uninstall
```

It installs a DKMS package (`hibernate/`) that rebuilds itself on every kernel upgrade,
configures `suspend-then-hibernate` on the lid, and fixes the sensor's 180° mounting.

### Surviving kernel upgrades

This is the part that used to break every time. All three modules — `ipu-bridge`,
`mei-vsc` and `ov02c10` — live inside one DKMS package with `AUTOINSTALL="yes"`, so
`apt` rebuilds and re-signs them whenever a kernel is installed. `ov02c10` matters most:
built by hand it quietly disappears with the old kernel, the stock one loads without the
`i2c_device_id`, and the post-S4 i2c client then binds to nothing.

What it cannot do is survive a kernel that changes the APIs these modules use. Then the
DKMS build fails, `apt` carries on, and you find out when the camera does not come back
from hibernation. So the failure is announced twice:

- **during `apt`**, by `/etc/kernel/postinst.d/zy-ipu6-hibernate-check`, which runs after
  DKMS and prints what is missing for the kernel just installed;
- **at login**, by a desktop notification, in case the apt output scrolled past.

Both call the same check, which you can also run yourself:

```bash
sudo ipu6-camera-healthcheck            # running kernel
sudo ipu6-camera-healthcheck 6.11.0-9   # any installed kernel
```

It is silent and exits 0 when everything is in place.

### A — why the resume crashed

An unbalanced reference count on the IVSC software node. The driver core pairs a
`kobject_get()` in `software_node_notify()` (at `device_add()`) with a `kobject_put()` in
`software_node_notify_remove()` (at `device_del()`) — but **that put is unconditional**,
sitting outside the `if (swnode->managed)` block that guards the second, extra put.

The fwnode is attached to `mei-csi` *after* the MEI bus has already added it, so the
add-side get never happens — while the del-side put always does. The MEI bus destroys and
recreates `mei-csi` on every resume, so the node loses one reference per cycle.
`INTC10CF-N` starts at 3 (itself plus its two port children), so the third resume frees
it, and `isys` walks the fwnode graph into freed memory:

```
refcount_t: addition on 0; use-after-free
 kobject_get / software_node_graph_get_port_parent
 fwnode_graph_get_endpoint_by_id
 isys_notifier_init [intel_ipu6_isys]
```

With `suspend-then-hibernate` the first cycle burns two resumes (the s2idle leg plus the
S4 resume), so the second cycle's first resume is the third. Hence "the second
hibernation".

`ipu_bridge_instantiate_ivsc()` is upstream code, so the missing get is an upstream bug
that only shows on hardware where the MEI bus resets:
[`hibernate/patches/0001-ipu-bridge-hold-a-reference-on-the-IVSC-swnode.patch`](hibernate/patches/0001-ipu-bridge-hold-a-reference-on-the-IVSC-swnode.patch).

### B — the sleep hook that hung the freeze, and two traps

**`systemd-sleep` runs every executable file in `/usr/lib/systemd/system-sleep/`,
regardless of its extension.** Renaming a hook to `something.disabled` does not disable
it. A leftover hook doing `unbind`/`bind` of vsc-tp and the IPU6 PCI device was still
running there and hanging the freeze. Check the `+x` bit, not the name.

**A hang at `Freezing user space processes` does not mean the kernel died there.**
journald is one of the processes frozen at that step, so the log always stops at that
line, hang or no hang.

### Testing it honestly

A plain `systemctl suspend` proves nothing — on a clean boot it does not recreate
`mei-csi` at all. `rtcwake` is worse: it bypasses the `systemd-sleep` hooks entirely and
can wedge the MEI stack (`mei mei1: device disabled`), which then needs a **full power
off**, since a warm reboot does not reset the VSC firmware.

The only valid test is the real one: close the lid, let it hibernate, open it, verify —
**and do it twice**. The failure was always on the second cycle.

The full write-up, with the timelines and the reference arithmetic, is in
[`hibernate/README.md`](hibernate/README.md).

---

## When the image freezes

A different failure, with a different fix. The CSI-2 link throws a `Frame sync error`,
the HAL pipeline sits waiting for frames that never arrive, and `v4l2loopback` keeps
serving the **last frame it cached** — so web pages say "paused" and Zoom shows a still
image instead of an error.

```bash
sudo dmesg | grep 'Frame sync error'
sudo systemctl restart v4l2-relayd@default.service
```

Usually it recovers on its own; the freeze is what happens when it does not.

---

## What hibernation actually breaks

> **Earlier versions of this README said the camera could not survive hibernation and
> that you should set the lid to plain suspend. That was wrong** — see
> [Hibernation](#hibernation) above. The analysis below was right about three layers and
> wrong about the fourth; it is kept because the reasoning is still useful.

Four things break when the machine powers off. The original diagnosis was:

| Layer | What happens | Verdict then | Verdict now |
|---|---|---|---|
| VSC firmware lost on power off | `vsc-tp: wakeup firmware failed ret: -110` | fixable in `mei_vsc` | fixed |
| mei-csi recreated without its fwnode | `mei-csi probed without device fwnode!` | fixable in `ivsc_csi` | fixed |
| Sensor loses its graph endpoint | `ov02c10: failed to check hwcfg: -517` | fixable | fixed |
| Sensor appears unpowered | `ov02c10: failed to find sensor: -5` (EIO) | **hardware, hopeless** | **fixed** |

The fourth was not a power problem at all. After S4 there is no ACPI i2c client for the
sensor and the ACPI one cannot be recreated, so the fix is to instantiate a **non-ACPI
i2c client whose primary fwnode is the software node**, and give `ov02c10` an
`i2c_device_id` so it matches that client. `-5` was the old, dead client talking to
nothing.

What *was* true: **the stack cannot be unloaded and reloaded**, so that is not a way out.

```
modprobe: FATAL: Module intel_ipu6_isys is in use.   (refcnt 6)
modprobe: FATAL: Module intel_ipu6      is in use.   (refcnt 9)
modprobe: FATAL: Module ov02c10         is in use.   (refcnt 5)
```

Those refcounts are held by registered V4L2/media devices, released only by the module's
`remove` — which you cannot reach without unloading it. Unbinding the PCI and SPI parents
does not drop them either. The IPU6 driver assumes it is never unloaded. Everything has
to be repaired in place, which is what the overlay does.

Also still true: hibernation barely drains the battery (~0.3%/hour measured), and if
yours aborts instantly — entering S4 and waking in the same second, never writing the
image — the laptop is Modern Standby only (`/sys/power/mem_sleep` offers just `[s2idle]`,
no `deep`) and needs:

```ini
# /etc/systemd/sleep.conf.d/20-hibernate-mode.conf
[Sleep]
HibernateMode=shutdown
```

`ipu6-hibernate-fix.sh` sets that for you.

---

## What the script does, manually

If you would rather not trust the script, this is exactly what it does.

### 1. Install packages

```bash
sudo apt install -y mokutil openssl v4l2loopback-dkms zstd ffmpeg v4l-utils \
    gstreamer1.0-tools v4l2-relayd gstreamer1.0-icamera \
    gstreamer1.0-libcamera libcamera-ipa libcamera-tools \
    linux-headers-$(uname -r)
```

### 2. Configure v4l2loopback

```bash
echo 'options v4l2loopback exclusive_caps=1 card_label="Intel MIPI Camera"' \
    | sudo tee /etc/modprobe.d/v4l2loopback.conf
echo 'v4l2loopback' | sudo tee /etc/modules-load.d/v4l2loopback.conf
sudo depmod -a && sudo modprobe v4l2loopback
```

### 3. Pick a pipeline

Check first:

```bash
ls /dev/ipu-psys0      # present → you can use the hardware ISP
cam -l                 # lists the sensor → libcamera is an option
```

```bash
sudo mkdir -p /etc/v4l2-relayd.d
cat <<EOF | sudo tee /etc/v4l2-relayd.d/default.conf
VIDEOSRC=icamerasrc buffer-count=7
FORMAT=NV12
WIDTH=1280
HEIGHT=720
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
EOF

sudo systemctl enable --now v4l2-relayd@default.service
```

If `/dev/ipu-psys0` is missing, use `VIDEOSRC=libcamerasrc` instead. Everything else
stays the same.

### 4. Secure Boot only — sign the module

```bash
sudo mkdir -p /var/lib/ipu6-camera-fix && sudo chmod 700 /var/lib/ipu6-camera-fix
sudo openssl req -new -x509 -newkey rsa:2048 \
    -keyout /var/lib/ipu6-camera-fix/MOK.priv \
    -outform DER -out /var/lib/ipu6-camera-fix/MOK.der \
    -days 36500 -subj "/CN=IPU6 Camera Module Signing Key/" -nodes
sudo chmod 600 /var/lib/ipu6-camera-fix/MOK.priv
sudo mokutil --import /var/lib/ipu6-camera-fix/MOK.der
sudo reboot     # then: Enroll MOK → Continue → Yes → password → Reboot
```

The module may be compressed. Decompress, sign, recompress:

```bash
KVER=$(uname -r)
SIGN_FILE="/usr/src/linux-headers-${KVER}/scripts/sign-file"
MODULE_PATH=$(modinfo -k "$KVER" -n v4l2loopback)

sudo cp "$MODULE_PATH" /tmp/v4l2loopback.ko.zst
sudo chmod 644 /tmp/v4l2loopback.ko.zst
zstd -d /tmp/v4l2loopback.ko.zst -o /tmp/v4l2loopback.ko --force
sudo "$SIGN_FILE" sha256 \
    /var/lib/ipu6-camera-fix/MOK.priv \
    /var/lib/ipu6-camera-fix/MOK.der \
    /tmp/v4l2loopback.ko
zstd -f /tmp/v4l2loopback.ko -o /tmp/v4l2loopback.ko.zst.new
sudo cp /tmp/v4l2loopback.ko.zst.new "$MODULE_PATH"
```

For an uncompressed `.ko`, skip the compression steps.

### 5. Verify — and mean it

```bash
v4l2-ctl --list-devices
ffmpeg -f v4l2 -i /dev/video0 -frames:v 60 -update 1 -y /tmp/test.png
```

If `/tmp/test.png` is only a few KB it is a black frame: the pipeline is not really
working, no matter how healthy `systemctl status` looks.

---

## Tested on

- Dell XPS 13 9340, sensor `ov02c10-uf`
- **Ubuntu 26.04.1 LTS (Resolute Raccoon)**, kernel `7.0.0-38-generic`
- Both pipelines verified end to end: `icamerasrc` (hardware ISP) and `libcamerasrc`
  (software ISP)
- Also previously tested on Ubuntu 24.04 with kernel 6.8
- Hibernation verified 2026-10-11 on kernel `7.0.0-1015-oem`: two consecutive
  hibernations in one boot, camera working and correctly oriented after each resume,
  no `refcount_t` warnings and the IVSC software node alive throughout

Originally written after finally getting the camera working by hand; I used vibe coding
to help turn it into a program. Read it before running it, and use it at your own risk.

---

## Claude Code skill

`skills/ipu6-camera/` holds the diagnostic procedure as a Claude Code skill, including
the approaches that look sensible and are wrong. See [`skills/README.md`](skills/README.md).

---

## License

MIT — for `ipu6-camera-fix.sh`, `ipu6-hibernate-fix.sh` and this README.

**`hibernate/` is GPL-2.0**, not MIT: it is derived from Linux kernel source and from the
GPL-2.0 `mei-vsc-hibernate` DKMS overlay by a third party (see
[`hibernate/README.md`](hibernate/README.md) for credit and provenance). Each source file
carries its original SPDX header, and those are authoritative.

### Original MIT terms

MIT

---

*Eduardo Ruiz Duarte — toorandom@gmail.com*
