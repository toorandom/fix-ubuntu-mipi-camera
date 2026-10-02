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

Originally written after finally getting the camera working by hand; I used vibe coding
to help turn it into a program. Read it before running it, and use it at your own risk.

---

## License

MIT

---

*Eduardo Ruiz Duarte — toorandom@gmail.com*
