# Extras

Two things that are not part of either installer but that you will probably want.

## `70-ipu6-hide-raw-nodes.rules` — stop apps listing ~48 fake cameras

The IPU6 exposes around 48 `/dev/videoN` nodes ("Intel IPU6 ISYS Capture N"). They are
raw sensor outputs and deliver nothing usable on their own — the picture comes from the
`v4l2loopback` device that `v4l2-relayd` writes to. But they all advertise
`ID_V4L_CAPABILITIES=:capture:`, so applications list every one of them.

In Zoom this is the difference between a camera picker with one working entry and one
with fifty, of which the plausible-looking "ipu6" ones produce nothing. People reasonably
conclude the fix did not work.

```bash
sudo cp 70-ipu6-hide-raw-nodes.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

The `70-` prefix matters: it has to run *after* `60-persistent-v4l.rules`, which is what
sets the capability in the first place. A lower number is silently overwritten.

## `fix-camera` — recover a frozen image

A different failure from a dead camera. The CSI-2 link throws `Frame sync error`, the HAL
waits for frames that never arrive, and `v4l2loopback` keeps serving the **last frame it
cached** — so the app shows a still image rather than an error, and web pages report the
camera as "paused".

```bash
install -m 0755 fix-camera ~/.local/bin/
fix-camera            # diagnose and recover
fix-camera --status   # diagnose only
```

It finds the camera **by label**, never by assuming `/dev/video0`: the number changes
between boots, and hardcoding it is how you end up with "Link has been severed".
