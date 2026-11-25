# 10 — USB stick, SD card and the two media slots

A rekordbox-exported stick in the SC Live 4's rear USB-A port is detected
natively: it mounts, `export.pdb` is opened and analysed by DeviceSQL, and the
drive shows as **USB 1** in rb.  On the Mixstream Pro Plus the panel's SD slot
is watched too and normally becomes **USB 2**; it does not need a rekordbox
export and is the default recording target.

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
  usb-watch.sh:  mount /dev/sda1 → /media/usb1/sda1 (vfat)          [slot 1]
                 mount --bind → /data/rbx3-run/media/usb1/sda1
                 FIFO /tmp/udev_usb1: "umount …" then "mount /media/usb1/sda1"
  rbp UsbMountManager → DbProxy → DbIF::mount(type=3)
  DeviceSQL (edb_streamd) opens export.pdb + exportExt.pdb and analyses the
  library → USB 1 appears in Source / Browse

SD card (mmc1) → mmcblk1/mmcblk1p1
  usb-watch.sh:  mount /dev/mmcblk1p1 → /media/usb4/sda1 (vfat/exfat) [slot 2]
                 mount --bind → /data/rbx3-run/media/usb4/sda1
                 FIFO /tmp/udev_usb2: one "umount …" / "mount …" pair
  no export.pdb needed; recordings go to PIONEER REC/
```

## Two media slots

`usb-watch.sh` watches both ports at once and assigns each device a slot:

| Slot | Host mount | Chroot bind | FIFO | Typical media |
|---|---|---|---|---|
| 1 | `/media/usb1/sda1` | `/data/rbx3-run/media/usb1/sda1` | `/tmp/udev_usb1` | library USB stick |
| 2 | `/media/usb4/sda1` | `/data/rbx3-run/media/usb4/sda1` | `/tmp/udev_usb2` | SD card (recording target) |

* **USB** devices are `sd*` whole disks whose sysfs path goes through one of
  `USBWATCH_BUSES` (default `1 2 3`).
* **SD** devices are `mmcblk*` whose `/sys/block/<dev>/device/type` is `SD`.
  The internal eMMC reports `MMC` and is never touched.
* Partition names differ: `sda1`, but `mmcblk1p1` (extra `p`).
* An SD card prefers slot 2 and a USB stick prefers slot 1, so with both
  inserted the library stick is USB1 and the card is USB2 regardless of
  insertion order. An attached device keeps its slot until removed/ejected;
  a third device waits for a free slot.
* Each slot publishes `/tmp/usb-name-N` (volume label) and `/tmp/usb-kind-N`
  (`usb`/`sd`). The shim's only recording gate is the presence of
  `/tmp/usb-name-2`; the kind file is diagnostic.
* Media containing `PIONEER/rekordbox/export.pdb` uses the retry-until-rbp-
  opens-it notification. Plain media (an SD card) gets a single
  `umount`/`mount` pair so the loop never stalls or interrupts a recording.

Both USB-A ports still work; with a single stick the watcher publishes it as
**USB1** (slot 1).

Sticks and cards are named by the kernel in attach order, so a second insert
(or a different device while the first was pulled) can appear as `sdb1` or
`mmcblk2p1`. `attach()` compares the slot mount's real source (`/proc/mounts`)
with the current partition: if `/media/usb1/sda1` (or `/media/usb4/sda1`) is
still mounted from a vanished device, it logs
`stale (…, want /dev/…) -> remounting`, drops the dead mount and mounts the
new device. A watcher restart with no media present also cleans a stale slot
mount (`detach: stale … with no media device`). Without this, rbp keeps
reading the dead tree and the kernel logs
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

## Recording to slot 2 (Mixstream Pro Plus)

**SHIFT + right-deck Wheel** toggles recording of the master mix to slot 2
(`/media/usb4/sda1/PIONEER REC`), normally the SD card. No rekordbox export is
needed; the shim calls `mixerengine::MixerEngine` directly (the native REC key
would only arm for a USB2 device with an attached export).

* Files: `RECTMP.WAV` while recording, renamed to `REC001.WAV` (next free
  number) on stop. Requires ~32 MB free; stops at `REC999.WAV` and at ~3 hours.
* The screen still shows rbp's REC icon and elapsed timer because the UI polls
  `DjEngineIF::getRecordingStatus()` / `getRecElapsedSec()`, which read the same
  `WavWriter`. Native error popups are not produced by this path; see
  `/tmp/knobshim.log` for `REC START` / `REC STOP` / `REC NOT READY`.
* A recording is closed before any unmount or power teardown via
  `/data/rec-stop.sh` and the `/tmp/rec-stop.req`/`.ack` mailbox.
* Full control reference: [08 — controls](08-controls.md#master-mix-recording-to-usb2-nh08s).

## Safe eject (Mixstream Pro Plus)

**SHIFT + SoundSwitch** stops rbp's USB managers (native `UsbStop 0x8002` on
manager channels 1 and 2), then hands a request to the host-side watcher:

```
knobshim2 → /tmp/usb-eject.req → usb-watch.sh (exits) → /data/usb-eject.sh
```

`usb-eject.sh` first closes any active recording, then unmounts both chroot
media binds and every mount backed by a removable device (`sdX` USB or
`mmcblkX` SD), syncs, and releases each device. USB sticks are removed via
`udisksctl power-off` (if present) or
`echo 1 > /sys/block/sdX/device/delete`; an SD card has no delete node, so
unmount + sync is reported as "safe to remove". Ejected devices are written to
`/tmp/usb-held` so the restarted watcher does not immediately remount a card
that is still in the slot; entries are pruned once the block device is gone.
An unshifted **SoundSwitch** press still opens SOURCE.

rbp needs a parallel stop burst by default; if only one deck stops on hardware,
start rbp with `USBSTOP_SEQUENTIAL=1` (and optionally
`USBSTOP_GAP_MS=150`). Full details and the power-button shutdown hook are in
[15 — NH08S power and eject](15-nh08s-power-and-eject.md).

## Files

* `scripts/device/usb-watch.sh` — two-slot hotplug watcher (USB + SD), shipped
  to `/data/usb-watch.sh`.
* `scripts/device/usb-eject.sh` — safe eject of all removable media
  (`/data/usb-eject.sh`), triggered by SHIFT + SoundSwitch
  ([15](15-nh08s-power-and-eject.md)).
* `scripts/device/rec-stop.sh` — stops a recording before unmount/power
  (`/data/rec-stop.sh`).
* `/data/timeout` — a small ARM `timeout(1)` helper required by
  `usb-watch.sh notify()`, `rec-stop.sh` and the eject script's FIFO writes.
* `fix-dev.sh` creates the `/tmp/udev_*` FIFOs and the `/etc/mtab` symlink.

## Run

```sh
sh /data/usb-watch.sh start    # one-shot; start-rb.sh does this automatically
sh /data/usb-watch.sh status   # both slots: mount, bind, label, held list
sh /data/usb-watch.sh stop
```

## Notes

* **`edisksd.service`** must stay stopped — it will bus-reset and unmount a
  storage device it doesn't manage (~30 s later).
* Media is re-notified automatically when rbp restarts (the watcher tracks the
  rbp pid); plain SD gets the single umount/mount pair again.
* A stick without a rekordbox export (no `PIONEER/rekordbox/export.pdb`) still
  mounts, but shows empty — folder browsing needs the native DB import. Such a
  stick in slot 2 is still a valid recording target.
