# fix-ubuntu-mipi-camera

Fix for Intel IPU6 MIPI cameras (ov02c10, ov08x40, etc.) on Ubuntu 22.04 / 24.04 with kernel 6.8+.

Many modern laptops with Intel 12th/13th gen CPUs have a MIPI camera connected through the Intel IPU6 ISP. These cameras do not appear as standard V4L2 devices and require:

- `v4l2loopback` kernel module (creates a virtual `/dev/videoN`)
- `v4l2-relayd` + `gstreamer1.0-icamera` to bridge the IPU6 pipeline to V4L2
- A signed kernel module if **Secure Boot** is enabled

This script automates the entire process, including Secure Boot MOK key generation, enrollment, and automatic re-signing on kernel updates.
After finally making the camera work, I used vibe coding to help me make this program. 

I tested the resulting script on a non-configured Ubuntu 24.04.4 LTS 6.17.0-20-generic with non-BIOS-signed driver over a Dell XPS 13 9340 and it worked. 
But read it first and use it at your own risk.

Any kernel should work, and the solution should be able to survive kernel upgrades.


**Author:** Eduardo Ruiz Duarte <toorandom@gmail.com>

---

## Supported hardware

- Intel IPU6 cameras: `ov02c10-uf`, `ov08x40`, and similar
- Ubuntu 22.04 / 24.04
- Kernel 6.8 and newer

---

## Quick start

```bash
sudo bash ipu6-camera-fix.sh
```

### Without Secure Boot

The script installs everything and loads the camera in a single run. Done.

### With Secure Boot (two phases)

Secure Boot requires the kernel module to be signed with a key trusted by the firmware. The script handles this in **two phases**:

---

#### Phase 1 — MOK key enrollment

```bash
sudo bash ipu6-camera-fix.sh
```

The script will:

1. Generate an RSA-2048 signing key pair stored in `/var/lib/ipu6-camera-fix/`
2. Register the public key with `mokutil --import`
3. **Ask you to set a temporary password** — write it down, you will need it at next boot
4. Offer to reboot immediately

At the blue **MOK Manager** screen after reboot:

```
1. Enroll MOK
2. Continue
3. Yes
4. Enter the password you just created
5. Reboot
```

---

#### Phase 2 — Sign, configure, load

After the system boots back into Ubuntu, run the script again:

```bash
sudo bash ipu6-camera-fix.sh
```

The script will:

1. Verify the key is enrolled in firmware
2. Sign the `v4l2loopback` module for the current kernel
3. Configure `v4l2loopback` to load at boot with label `Intel MIPI Camera`
4. Install a systemd service (`sign-v4l2loopback`) that automatically re-signs the module after every kernel update
5. Configure `v4l2-relayd` to bridge the IPU6 GStreamer pipeline to `/dev/videoN`
6. Load the module and start the camera

When done you will see the camera device, e.g. `/dev/video0`, and a test command:

```bash
ffplay -f v4l2 -i /dev/video0
```

---

## Uninstall

```bash
sudo bash ipu6-camera-fix.sh --uninstall
```

This will:

- Stop and disable `sign-v4l2loopback` and `v4l2-relayd` services
- Unload the `v4l2loopback` module
- Remove all config files created by the script
- Queue the MOK key for deletion from firmware (if enrolled)

If the key was enrolled, a reboot is required and you will need to confirm the deletion at the MOK Manager blue screen (same flow as enrollment, but choosing **Delete MOK**).

---

## What the script does — manual steps

If you prefer to do everything by hand, here is exactly what the script does:

### 1. Install packages

```bash
sudo apt install -y mokutil openssl v4l2loopback-dkms zstd ffmpeg v4l-utils \
    gstreamer1.0-tools v4l2-relayd gstreamer1.0-icamera \
    linux-headers-$(uname -r)
```

### 2. Generate a MOK signing key pair

```bash
sudo mkdir -p /var/lib/ipu6-camera-fix
sudo chmod 700 /var/lib/ipu6-camera-fix

sudo openssl req -new -x509 -newkey rsa:2048 \
    -keyout /var/lib/ipu6-camera-fix/MOK.priv \
    -outform DER -out /var/lib/ipu6-camera-fix/MOK.der \
    -days 36500 \
    -subj "/CN=IPU6 Camera Module Signing Key/" \
    -nodes

sudo chmod 600 /var/lib/ipu6-camera-fix/MOK.priv
```

### 3. Enroll the key with MOK (Secure Boot only)

```bash
sudo mokutil --import /var/lib/ipu6-camera-fix/MOK.der
# Enter a temporary password when prompted — you'll need it at next boot
sudo reboot
```

At the blue MOK Manager screen: **Enroll MOK → Continue → Yes → enter password → Reboot**.

### 4. Ensure the DKMS module is built

```bash
KVER=$(uname -r)
VER=$(dkms status v4l2loopback | grep -oP '\d+\.\d+\.\d+' | head -1)
sudo dkms install "v4l2loopback/${VER}" -k "$KVER" --force
```

### 5. Sign the module

The module may be compressed (`.ko.zst`, `.ko.gz`, `.ko.xz`) — decompress, sign, recompress:

```bash
KVER=$(uname -r)
SIGN_FILE="/usr/src/linux-headers-${KVER}/scripts/sign-file"
MODULE_PATH=$(modinfo -k "$KVER" -n v4l2loopback)

# Example for .ko.zst (most common on Ubuntu 24.04):
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

For uncompressed `.ko`: skip the compress/decompress steps.

### 6. Configure v4l2loopback to load at boot

```bash
echo 'options v4l2loopback exclusive_caps=1 card_label="Intel MIPI Camera"' \
    | sudo tee /etc/modprobe.d/v4l2loopback.conf

echo 'v4l2loopback' | sudo tee /etc/modules-load.d/v4l2loopback.conf
```

### 7. Install the boot re-signing service

Create `/usr/local/sbin/sign-v4l2loopback.sh` with the signing logic from step 5 (detecting the current kernel and compression format), then:

```bash
# /etc/systemd/system/sign-v4l2loopback.service
[Unit]
Description=Sign v4l2loopback for Secure Boot (kernel-update safe)
DefaultDependencies=no
Before=modprobe@v4l2loopback.service systemd-modules-load.service modules-load.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sign-v4l2loopback.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable sign-v4l2loopback.service
```

### 8. Configure v4l2-relayd

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
```

### 9. Load the module and start the camera

```bash
sudo depmod -a
sudo modprobe v4l2loopback
sudo systemctl enable --now v4l2-relayd@default.service
```

Check the camera device:

```bash
v4l2-ctl --list-devices
ffplay -f v4l2 -i /dev/video0
```

---

## License

MIT

---

*Eduardo Ruiz Duarte — toorandom@gmail.com*
