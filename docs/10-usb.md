# 10 — USB stick + rekordbox database

A rekordbox-exported stick in the SC Live 4's rear USB-A port is detected
natively: it mounts, `export.pdb` is opened and analysed by DeviceSQL, and the
drive shows as **USB 1** in rb.

The flow uses `usb-watch.sh` with two SC Live 4 specifics:

1. **The media port is on `usb1` (DWC OTG)**, not `usb3/usb4` as on the Prime
   GO. A stick in the back enumerates as:
   ```
   /sys/block/sda -> ../platform/ff540000.usb/usb1/1-1/1-1:1.0/host0/.../block/sda
   ```
   The control surface is a MIDI UART (card 0), *not* USB, so `usb1` is free
   for media. `USBWATCH_BUSES="1 2 3"` (the shipped default) watches all ports.

2. **`PATH` must include `/bin`** when launching rbp. The SC Live 4's default
   `PATH` is `/usr/bin:/usr/sbin`, but the chroot's busybox tools (`ls`, …) live
   in `/bin`. Without it rbp logs `sh: ls: not found` and the mount-handler
   helpers fail. `start-rb.sh` sets
   `PATH=/bin:/sbin:/usr/bin:/usr/sbin`.

## Working chain

```
stick (usb1, 1-1) → sda/sda1
  usb-watch.sh:  mount /dev/sda1 → /media/usb1/sda1 (vfat)
                 mount --bind → /data/rbx3-run/media/usb1/sda1
                 FIFO /tmp/udev_usb1: "umount …" then "mount /media/usb1/sda1"
  rbp UsbMountManager → DbProxy → DbIF::mount(type=3)
  DeviceSQL (edb_streamd) opens export.pdb + exportExt.pdb and analyses the
  library → USB 1 appears in Source / Browse
```

Both USB-A ports work; the watcher publishes either as **USB1** (it always
uses `/media/usb1/sda1`). Inserting the stick updates rbp's detect/media
state (visible as `knobshim2: USB1 detected -> registered (dev=3)`).

Sticks are named by the kernel in attach order, so a second insert (or a
different stick while the first was pulled) can appear as `sdb1`. `attach()`
compares the mount's real source (`/proc/mounts`) with the current partition:
if `/media/usb1/sda1` is still mounted from a vanished `/dev/sda1`, it logs
`stale (…, want /dev/sdb1) -> remounting`, drops the dead mount and mounts the
new device. A watcher restart with no media present also cleans a stale
`/media/usb1/sda1` (`detach: stale … with no media device`). Without this,
rbp keeps reading the dead tree and the kernel logs
`FAT-fs (sda1): Directory bread(block …) failed`.

## Selecting the source (Mixstream Pro Plus)

The XDJ-RX3 has a hardware **SOURCE** button; the Mixstream does not, and its
Engine-OS source picker is touch-only. rbp ignores touch in this menu, so
`knobshim2.c` supplies the key:

1. With a mounted stick and **no source selected**, pushing the **Browse**
   knob opens the SOURCE menu (sends `K_SOURCE 0x0201`).
2. With the SOURCE menu open, pushing **Browse** selects **USB1** (sends
   `K_USB1 0x0209`); the track list populates.
3. **SoundSwitch (note 34, ch15)** is repurposed as a SOURCE button, so the
   menu can be reopened at any time (also selects USB1 with a second Browse
   push).

The detection uses rbp's live state: `browseMode` at `0x326f8b8`,
browse device at `0x326f8bc` (0 = none, 3 = USB1) and the mounted
`PIONEER/rekordbox/export.pdb`.

## Safe eject (Mixstream Pro Plus)

**SHIFT + SoundSwitch** stops rbp's USB managers (native `UsbStop 0x8002` on
manager channels 1 and 2), then hands a request to the host-side watcher:

```
knobshim2 → /tmp/usb-eject.req → usb-watch.sh (exits) → /data/usb-eject.sh
```

`usb-eject.sh` unmounts the chroot bind and every mount backed by a USB `sdX`,
syncs, and removes each device via `echo 1 > /sys/block/sdX/device/delete`
(`udisksctl power-off` is used only if that tool exists). The watcher restarts
afterwards, so a reinserted stick mounts as USB1 again without restarting rbp.
An unshifted **SoundSwitch** press still opens SOURCE.

rbp needs a parallel stop burst by default; if only one deck stops on hardware,
start rbp with `USBSTOP_SEQUENTIAL=1` (and optionally
`USBSTOP_GAP_MS=150`). Full details and the power-button shutdown hook are in
[15 — NH08S power and eject](15-nh08s-power-and-eject.md).

## Files

* `scripts/device/usb-watch.sh` — hotplug watcher (SC Live 4 buses), shipped to
  `/data/usb-watch.sh`.
* `scripts/device/usb-eject.sh` — safe eject of all USB media (`/data/usb-eject.sh`),
  triggered by SHIFT + SoundSwitch ([15](15-nh08s-power-and-eject.md)).
* `/data/timeout` — a small ARM `timeout(1)` helper required by
  `usb-watch.sh notify()` and the eject script's FIFO write.
* `fix-dev.sh` creates the `/tmp/udev_*` FIFOs and the `/etc/mtab` symlink.

## Run

```sh
sh /data/usb-watch.sh start    # one-shot; start-rb.sh does this automatically
sh /data/usb-watch.sh status   # mounted? chroot bind? media sd?
sh /data/usb-watch.sh stop
```

## Notes

* **`edisksd.service`** must stay stopped — it will bus-reset and unmount a
  storage device it doesn't manage (~30 s later).
* The stick is re-notified automatically when rbp restarts (the watcher tracks
  the rbp pid).
* A stick without a rekordbox export (no `PIONEER/rekordbox/export.pdb`) still
  mounts, but shows empty — folder browsing needs the native DB import.
