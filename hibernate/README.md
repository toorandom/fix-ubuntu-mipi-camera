# mei-vsc-hibernate — IPU6 / IVSC camera across hibernation

**Licence: GPL-2.0** (not the MIT of the rest of this repository — see `LICENSE` here).

## Credit and provenance

This is an adaptation of the GPL-2.0 DKMS overlay **`mei-vsc-hibernate` 1.18**, written
by a third party for a **Dell Precision 5690** with an **ov02e10** sensor on Ubuntu 24.04
/ kernel 7.0.0-31-generic. That work did the hard part — the non-ACPI swnode i2c client,
the freeze-time teardown, and the long list of approaches that Oops (documented in its
"Do not" section, all of it still worth reading). We have not been able to identify the
original author or a canonical URL; **if that is you, please open an issue and we will
credit you properly.**

What this fork changes:

- **Retargeted to `ov02c10`** on a **Dell XPS 13 9340** (`OVTI02E1` → `OVTI02C1`,
  `ov02e10` → `ov02c10`), including the sensor's `i2c_device_id` patch.
- **Fixes the unbalanced reference count on the IVSC software node** (v1.19), which is
  what crashed the resume. See below and `patches/0001-*.patch` — that one is an upstream
  bug, not specific to this overlay.
- **Ships `ov02c10` inside the DKMS package** (v1.20) so a kernel upgrade rebuilds it.
  Installed by hand it silently disappears on the next kernel, and the camera stops
  coming back from hibernation with no obvious cause.
- Makes this overlay's own sleep hook actually run on the lid path (it guarded on
  `hibernate`, but systemd passes `suspend-then-hibernate`).

Upstream's warning applies unchanged: **this is a workaround, not an upstream patch
series. Use at your own risk.** Secure Boot needs these modules signed with your MOK.

GPL-2.0 overlay for in-tree `mei-vsc` + `ipu-bridge`. Tested on Dell Precision 5690, Ubuntu 24.04, kernel **7.0.0-31-generic**. **Two hibernates in one boot** (2026-09-07): sensor rebound as a non-ACPI i2c client (`18-0010`, `companion=none`), no Oops, no `refcount_t underflow`.

This is a **workaround**, not an upstream patch series. Use at your own risk. Secure Boot must allow these modules (unsigned or your MOK).

**Do not use 1.9–1.15 for repeated S4.** First hibernate often worked; the second Oopsed in `acpi_dev_pm_detach` after restoring `OVTI02E1-N` as the ACPI primary’s secondary fwnode.

**1.16** survived two S4s but freeze #1 WARNed `refcount_t underflow` (extra `put_device` on the cold-boot ACPI i2c client). **1.18** skips that put; freeze of the swnode client is unchanged.

Also required: ov02e10 must match `i2c:ov02e10` (`patches/ov02e10-i2c-device-id.patch`). On this machine that lives in DKMS `ipu6-drivers`. In-tree ov02e10 needs the same `i2c_device_id` or the swnode client will not bind.

## Do not

- Unload IPU6 in a systemd-sleep hook (INT343E `-EEXIST`).
- Copy v1.8’s “always reattach when the IPU graph exists” — that Oopses `isys_runtime_pm_suspend` on cold boot.
- Restore `OVTI02E1-N` as ACPI `primary->secondary` after S4 (v1.9–1.15 Oops).
- Sysfs-bind `intel_ipu6.psys.40` after an isys Oops (D-state hang; reboot will not finish).

## Install

```bash
cd mei-vsc-hibernate-1.18
# ov02e10 i2c_device_id — apply to the ov02e10 you actually load (DKMS or in-tree), rebuild that module
sudo ./install.sh
```

Reboot. `modinfo ipu-bridge` / `mei-vsc` `filename` must be under `updates/dkms/`. `modinfo ov02e10` must list `alias: i2c:ov02e10`.

Undo: `sudo dkms remove mei-vsc-hibernate/1.18 --all && sudo reboot`

## Test

1. Cold boot: no `ipu_bridge: deferred reattach` if mei-csi already has a fwnode; dmesg has `psys probe minor: 0`; no isys Oops; ov02e10 bound (ACPI client is OK on cold boot).
2. `systemctl hibernate`. Resume: dmesg has `unregister ACPI i2c` / `drop ACPI i2c` then `swnode i2c client … companion=none`; ov02e10 bound on a numeric i2c device (here `18-0010`), not `i2c-OVTI02E1:00`. Freeze must **not** log `refcount_t underflow`.
3. **Hibernate a second time.** Pass: `unregister swnode i2c` on freeze; same `companion=none` on resume; ov02e10 bound; no Oops. First I2C `-5` then delayed bind is expected (USB LJCA).
4. Pass/fail is ov02e10 + ivsc_csi + IPU6 isys/psys in sysfs. A USB webcam is not a pass.

Stock (no overlay) after S4: `wakeup firmware failed ret: -110`, `hwcfg: -517`, `mei-csi probed without device fwnode!`, sensor unbound.

Opening the camera in the first ~12s after S4 can time out even when the overlay is about to succeed (USB LJCA). Wait, then retry.

## v1.19 — the second-hibernation hang: root cause

Up to v1.18 the first hibernation recovered the camera but the **second one hung the
machine**. The trigger was an unbalanced reference count on the IVSC software node
(`INTC10CF-4`), not anything hibernation-specific.

The driver core pairs these two:

| | hook | effect on `dev_to_swnode(dev)` |
|---|---|---|
| `device_add()` | `software_node_notify()` | `kobject_get()` |
| `device_del()` | `software_node_notify_remove()` | `kobject_put()` |

The `kobject_put()` in `software_node_notify_remove()` is **unconditional** — it sits
*outside* the `if (swnode->managed)` block that guards the second, extra put.

Both `ipu_bridge_instantiate_ivsc()` (upstream, cold boot) and our
`ipu_bridge_attach_swnode()` (resume) call `set_secondary_fwnode(csi_dev, fwnode)`
*after* the MEI client bus has already run `device_add()` on `mei-csi`. So the add-side
`kobject_get()` never happens for that node — but the del-side `kobject_put()` always
does. The MEI bus destroys and recreates `mei-csi` on **every** bus reset, i.e. on every
s2idle and S4 resume, so the node loses one reference per resume cycle.

`INTC10CF-4` starts at refcount **3**: one for its own registration plus one each for its
two port children (`kobject_add()` of a child takes a reference on the parent). Hence:

```
boot                    3
mei-csi #1 device_del   2
mei-csi #2 device_del   1
mei-csi #3 device_del   0   -> node freed and dropped from swnode_kset
```

On the third resume `software_node_find_by_name()` returns NULL (`no INTC10CF-N swnode`)
and `isys_probe()` walks into freed memory:

```
refcount_t: addition on 0; use-after-free
 kobject_get
 software_node_graph_get_port_parent
 fwnode_graph_get_port_parent
 fwnode_graph_get_endpoint_by_id
 isys_notifier_init [intel_ipu6_isys]
 isys_register_devices / isys_probe
 deferred_probe_work_func
```

This is why it was always the *second* hibernation: with `suspend-then-hibernate` the
first cycle burns two resumes (the s2idle leg plus the S4 resume) and the second cycle's
first resume is the third.

**Fix:** take and keep a reference on the IVSC node at every attach, balancing the put the
core will do when that `csi_dev` is destroyed — `fwnode_handle_get()` in
`ipu_bridge_instantiate_ivsc()`, and simply not dropping the reference that
`software_node_find_by_name()` already took in `ipu_bridge_attach_swnode()`.

The sensor-side helpers (`ipu_bridge_reattach_sensor_swnodes()`,
`ipu_bridge_sensor_bound()`, `ipu_bridge_destroy_sensor_i2c_clients()`) leak one
`find_by_name()` reference each. That is deliberate for now: it is a leak rather than an
underflow, and it is what has been keeping `OVTI02C1-4` alive through the same core bug.

`ipu_bridge_instantiate_ivsc()` is upstream code, so the missing get looks like a genuine
upstream bug that only shows on hardware where the MEI bus resets — worth sending up.

## v1.19 — the other half: a legacy sleep hook nobody had disabled

Fixing the refcount got the machine past the resume that used to die, but the second
hibernation still hung — now later, in `Freezing user space processes` on the way *into*
S4. Journald is frozen at that very step, so the log simply stops there and gives nothing.

The cause was in userspace. An older hook, `50-ipu6-camera`, was still installed as
`50-ipu6-camera.disabled` — **and `systemd-sleep` runs every executable file in
`/usr/lib/systemd/system-sleep/` regardless of its extension**, so the `.disabled` in the
name disabled nothing. It had kept its `+x` bit and kept running.

That hook predates this overlay and does by hand what the overlay now does in the kernel:
`unbind`/`bind` of `spi-INTC10D0:00` (vsc-tp) and `0000:00:05.0` (intel-ipu6), with ~20s
of `sleep` in between. On the lid path it ran on *every* leg, so its rebuild finished
**100 ms before** the hibernate leg began, with deferred probe work still in flight:

```
14:26:01.312  ipu6-camera-sleep: rebuilding camera stack
14:26:21.286  ipu6-camera-sleep: rebuild done (psys: ok)
14:26:21.385  ipu6-camera-sleep: stopping relayd before suspend-then-hibernate
14:26:21.397  systemd-sleep: Performing sleep operation 'hibernate'
14:26:21.518  Freezing user space processes      <- hang
```

Those repeated unbind/bind cycles were also what kept recreating `mei-csi`, i.e. they were
the source of the unbalanced `kobject_put()` described above. One hook, both symptoms.

Removing it (moved out of the directory, not renamed) let both hibernations complete.

**Also fixed:** this overlay's own hook guarded on `[[ "$action" == hibernate ]]`, but the
lid path is `suspend-then-hibernate` and systemd passes *that* action — so the hook had
never run there at all. It now accepts both.

### Verified 2026-10-11

Two consecutive hibernations in one boot, something this machine had never managed:
`INTC10CF-4` alive throughout, no `refcount_t` warnings, `ov02c10 bound after delay` and a
working camera after each resume.

### Sensor orientation

The `ov02c10` is mounted at 180° here, and nothing applies that automatically. The flips
live on the sensor subdev, whose number changes on every boot and every post-S4 re-probe,
so `71-ipu6-sensor-orientation.rules` triggers `ipu6-sensor-orientation@.service` on the
subdev's udev `add`. It must set *and verify* in a loop: `ipu_bridge` does a deferred
re-probe right after the udev event (`ov02c10 bound after delay`) and that bind resets the
sensor registers, wiping a single-shot write.
