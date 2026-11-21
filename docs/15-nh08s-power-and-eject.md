# 15 — NH08S safe USB eject and power-button shutdown

Two NH08S-specific gestures make USB media and power-off safe while rbp is
driving the hardware:

| Gesture | Effect |
|---|---|
| **SHIFT + SoundSwitch** (the printed *lighting* button, ch15 note 34) | rbp's native USB stop on both USB manager channels, then unmount + remove every USB mass-storage drive |
| **Power button** | stop rbp/`edb_streamd`, eject USB media, release the chroot binds, `sync`, then power off — using the stock `az01-power-button.service` timing |

Plain **SoundSwitch** keeps its existing rbp `SOURCE` behaviour
([10](10-usb.md)); only the SHIFT-qualified press ejects.

**How long to press:** SHIFT + SoundSwitch is edge-triggered on the button-down
event — hold deck SHIFT, tap SoundSwitch briefly, then release. No hold is
needed for the eject. The power button keeps the stock daemon's debounce, which
requires a **long press of just over 6 seconds** before it calls `reboot()`; a
short press does nothing.

The implementation lives in:

* `scripts/shims/knobshim2.c` — gesture, native keycode, request mailbox.
* `scripts/device/usb-eject.sh` — OS-level unmount + device removal.
* `scripts/device/rbp-shutdown.sh` — graceful teardown for the power hook.
* `scripts/device/poweroff-hook.c` → `poweroff-hook.so` — `reboot()` interposer.
* `scripts/device/start-rb.sh` — installs the runtime power-button drop-in.
* `scripts/device/stop-rbp-return-engine.sh` — removes it when handing back
  to Engine OS.

## 1. Eject: SHIFT + SoundSwitch

### rbp's native stop first

`extracted/rbp-audio` shows `ui::KeyInput::keyCodeAsText()` maps keycode
**`0x8002`** to `"UsbStop"`. `ui::UsbStorageManager::onKey()` accepts it only
when `IKeyInput+8 == 0x8002` **and** `IKeyInput+10 ==` that manager's channel.
rbp creates one USB manager per source, and they use **channels 1 and 2**, so
the shim sends `K_USBSTOP = 0x8002` on both:

```
send_rx_key(0x8002, OP_PRESS,   1, 0)
send_rx_key(0x8002, OP_PRESS,   2, 0)
send_rx_key(0x8002, OP_RELEASE, 1, 0)
send_rx_key(0x8002, OP_RELEASE, 2, 0)     # default: parallel
```

This is the *parallel* mode, mirroring the RX3's two physical USB STOP
buttons. If a parallel burst races inside rbp's `UsbStopReqHandler`, launch rbp
with `USBSTOP_SEQUENTIAL=1` to send channel 1, wait `USBSTOP_GAP_MS`
(default 150 ms), then channel 2 — no rebuild needed. `start-rb.sh` passes both
variables into the chroot.

The stop is sent from a one-shot detached thread (`usb_stop_thread()`), so the
MIDI callback never blocks. A `usb_eject_active` latch ignores repeated presses
until the worker finishes. The `SHIFT` state is the OR of both deck SHIFTs
(note 28 on the NH08S deck channels), the same latch used by Settings, VIEW and
the pads.

### Host-side mailbox

rbp is chrooted (`/data/rbx3-run`) and cannot execute `/data/*`. The shim
therefore writes a one-line request to the bind-mounted host `/tmp`:

```
<unix-seconds> <parallel|sequential>\n      → /tmp/usb-eject.req
```

`usb-watch.sh` polls the host `/tmp` once a second. When it sees the request it

1. drops requests older than **15 s** or with a malformed timestamp,
2. removes its PID file and **exits** (so its 1 s loop cannot remount the
   stick during the eject),
3. starts `usb-eject.sh` detached with `setsid`.

```
SHIFT+n34 → knobshim2 → rbp 0x8002 ch1+ch2
                    └──→ /tmp/usb-eject.req
                              ↓ (host /tmp, bind-mounted into the chroot)
                        usb-watch.sh (exits)
                              ↓
                        /data/usb-eject.sh
```

### `usb-eject.sh`

1. Takes a PID-checked lock (`/tmp/usb-eject.lock.d`) so a double press only
   runs one eject.
2. Discovers **all** `/sys/block/sd*` whose sysfs path contains `/usb` — every
   USB mass-storage device, not only `sda1`. The `removable` flag is not used:
   USB-SATA bridges report `0` but are still external media.
3. `sh /data/usb-watch.sh stop` (normally a no-op: the watcher exited already).
4. Notifies rbp `umount /media/usb1/sda1` through `/tmp/udev_usb1` so its
   `PathDecider` state is reset. A missing reader is skipped (shutdown path);
   the static `/data/timeout` helper bounds the FIFO open.
5. `sync`, unmounts the chroot bind `/data/rbx3-run/media/usb1/sda1` and every
   mountpoint backed by `/dev/sdX*`, with a lazy fallback.
6. For each device: `udisksctl power-off -b /dev/sdX` if the tool exists (it
   does not on this firmware), then the primary path
   `echo 1 > /sys/block/sdX/device/delete`, waiting up to 3 s for the device to
   disappear.
7. Restarts `usb-watch.sh` (unless called with `--shutdown`).

Logs: `/data/usb-eject.log` (full detail) and `/tmp/knobshim.log` (one-line
result). With no stick attached the gesture is a logged no-op.

### Reinsertion

`device/delete` removes the kernel's SCSI device, so the next insertion is
enumerated from scratch (`sda1` again, not a stale `sdb1`) and mounts as **USB
1** without restarting rbp. If it does not appear, check
`/data/usb-eject.log` for an unmount failure and re-run
`sh /data/usb-watch.sh start`.

## 2. Power button

`az01-power-button.service` is a static, always-active unit running
`/usr/bin/az01-pwrbtn`. The daemon keeps its own GPIO/debounce handling and
calls libc `reboot(RB_POWER_OFF)`; it is *not* replaced. Disassembly of the
stock binary shows it compares the press duration against `0x5B8D7F`
(5,999,999 µs), so the button must be held for **about 6 seconds or longer**;
we deliberately leave that timing unchanged.

Instead, `start-rb.sh` installs a **runtime** drop-in (the root filesystem is
read-only, so `/etc` cannot be changed):

```
/run/systemd/system/az01-power-button.service.d/override.conf
[Service]
Environment=LD_PRELOAD=/data/poweroff-hook.so
```

then `systemctl daemon-reload` + `restart az01-power-button.service`. If the
daemon does not come back active, the drop-in is removed and the daemon is
restarted clean so the power button never stops working.

`poweroff-hook.so` (armhf, hard-float, only `GLIBC_2.4` symbols) interposes
`reboot()`:

1. `RB_POWER_OFF`, `RB_HALT_SYSTEM` and `RB_AUTOBOOT` first run
   `/data/rbp-shutdown.sh` synchronously (fork + `execl`, with `LD_PRELOAD`
   cleared for the child and a 20 s `alarm()` safety valve).
2. The recursive-call guard is the environment variable
   `RBP_SHUTDOWN_HOOK_ACTIVE`.
3. It then performs the real poweroff with the raw `SYS_reboot` syscall, so the
   daemon still powers the device off exactly as before.

`rbp-shutdown.sh`:

1. logs to `/data/rbp-shutdown.log`; serialises repeated presses with
   `/tmp/rbp-shutdown.lock.d`;
2. `sh /data/stop-rbp` (stops the USB watcher, rbp, `edb_streamd`, capture);
3. `sh /data/usb-eject.sh --shutdown` (unmount + remove USB, **no** watcher
   restart);
4. unmounts `/data/rbx3-run/{media/usb1/sda1,dev,proc,sys,tmp}` and `sync`;
5. **never** calls `poweroff`/`reboot` itself — the hook does that after the
   script returns.

After the next boot the chroot binds are intact (or absent) and `/dev` is
untouched because nothing was deleted through the bind mounts.

## 3. Build and deploy

Build the shim and the hook on the host:

```sh
make -C scripts/shims knobshim2.so RX3=$PWD/extracted/XDJRX3-rootfs
make -C scripts/device CROSS=arm-linux-gnueabihf- timeout poweroff-hook.so
```

Verify the shim is soft-float and only references GLIBC ≤ 2.7
(`make -C scripts/shims check`); the power hook may use GLIBC_2.4 only and must
match the stock daemon's armhf ABI.

Deploy the device scripts next to `start-rb.sh` (they are not inside
`rbx3-run.tgz`):

```sh
scp scripts/shims/knobshim2.so \
    scripts/device/usb-eject.sh \
    scripts/device/rbp-shutdown.sh \
    scripts/device/poweroff-hook.so \
    scripts/device/timeout \
    root@<device>:/data/
ssh root@<device> 'chmod 755 /data/usb-eject.sh /data/rbp-shutdown.sh \
                             /data/poweroff-hook.so /data/timeout'
```

`start-rb.sh` also copies `/data/knobshim2.so` over the chroot copy, so the
shim must be updated in both places: ship it in `work/rbx3-run.tgz` **and** as
`/data/knobshim2.so`.

`knobshim2.so` ships inside `work/rbx3-run.tgz` as
`/usr/lib/knobshim.so`. Restart rbp with `sh /data/start-rb.sh`; the log
contains

```
power hook: installed (LD_PRELOAD=/data/poweroff-hook.so)
```

and `/tmp/knobshim.log` (with `KNOB_VERBOSE=1`) shows the chosen stop mode when
the gesture fires.

Handing the device back to Engine OS
(`sh /data/stop-rbp-return-engine.sh`) removes the drop-in and restarts the
power daemon without the preload.

## 4. Verify

Ask before driving hardware tests. The safe order is:

1. **Plain SoundSwitch** → still opens rbp's SOURCE menu (`ch15 note34 ->
   0x0201`).
2. **SHIFT + SoundSwitch with a stick loaded**: `knobshim2: usb stop parallel:
   ch1+ch2`, both decks stop, `/data/usb-eject.log` ends with `=== eject ok ===`
   and `/sys/block/sda` is gone. If only one deck stops or the unmount fails,
   restart rbp with `USBSTOP_SEQUENTIAL=1` and retest; keep whichever mode
   works as the default.
3. Press again with no media → logged no-op, no error dialog.
4. Reinsert the stick → it mounts and rbp re-registers USB1 without a restart.
5. **Power button** → `/data/rbp-shutdown.log` shows the teardown, the panel
   dies, and the device powers off. On the next boot `/dev` is intact and no
   stale `/data/rbx3-run/*` mounts remain.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| SHIFT + SoundSwitch does nothing | plain press still goes to SOURCE; the SHIFT press must be down *before* SoundSwitch | hold deck SHIFT first; check `KNOB_VERBOSE=1` in `/tmp/knobshim.log` |
| `shift+SoundSwitch ignored (eject in progress)` | latch still set from a previous press | wait a second; a failed eject clears the latch when the worker returns |
| rbp stops only one deck | parallel `UsbStop` coalesced/raced | restart rbp with `USBSTOP_SEQUENTIAL=1` (`USBSTOP_GAP_MS` to tune) |
| Eject log says `unmount FAILED` | a file is still open in the mount | close playback/browser; the script falls back to lazy unmount and still tries the device delete |
| Stick remounts after eject | the watcher was restarted too early, or `edisksd` is running | the watcher is stopped during eject; ensure `edisksd.service` is stopped ([10](10-usb.md)) |
| Power button still hard-powers-off | hook not installed (missing `.so`/script, or daemon restart failed) | check `systemctl cat az01-power-button.service` for the drop-in, `/data/start-rb.log`, and `/data/rbp-shutdown.log` |
| Power-button hook is active in Engine OS | `start-rb.sh` ran but Engine was restored without `stop-rbp-return-engine.sh` | run `sh /data/stop-rbp-return-engine.sh`, or remove `/run/systemd/system/az01-power-button.service.d` and restart the unit |
| No `/data/rbp-shutdown.log` after pressing power | the daemon did not call libc `reboot()` (or the hook failed to load) | check `systemctl status az01-power-button.service` and the daemon environment; the raw-syscall fallback is a dedicated KEY_POWER listener |

## 6. Files and logs

| Path | Role |
|---|---|
| `/data/usb-eject.sh` | unmount + remove all USB media |
| `/data/usb-eject.log` | per-step eject log |
| `/tmp/usb-eject.req` | shim → watcher mailbox |
| `/tmp/usb-eject.lock.d` | eject serialisation |
| `/data/rbp-shutdown.sh` | graceful teardown for the power hook |
| `/data/rbp-shutdown.log` | shutdown log |
| `/data/poweroff-hook.so` | `reboot()` interposer preloaded into `az01-pwrbtn` |
| `/run/systemd/system/az01-power-button.service.d/override.conf` | runtime drop-in (ephemeral) |
