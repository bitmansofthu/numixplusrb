# scripts/device/

On-device scripts (ship to `/data/` on the SC Live 4 or Mixstream Pro / Pro Plus).

| Script | Purpose |
|---|---|
| `fix-dev.sh` | bind mounts (`/dev /proc /sys /tmp`), device stubs, `/tmp/udev_*` FIFOs, `etc/mtab` symlink. Run after every reboot. |
| `start-rb.sh` | stop Engine OS + `edisksd`, prepare the chroot, select the JP21/NH08 audio layout from the device tree, start `edb_streamd` then `rbp`, start the USB watcher. |
| `start-rbp-debug.sh` | same, but detached with `KNOB_VERBOSE=1` + `FBSHIM_DEBUG=1` and an `aseqdump` raw-MIDI capture; logs go to `/tmp/{knobshim,audioshim,seqdump}.log` and touch events to `/data/rbp-p.log`. Re-running restarts rbp. |
| `stop-rbp` | stop rbp + `edb_streamd` + the USB watcher (panel keeps the last frame; Engine is **not** restarted). |
| `stop-rbp-return-engine.sh` | `stop-rbp`, remove the runtime power-button drop-in, then `reset-failed` + start `engine.service` and the `edisksd`/`enginex-*` units. |
| `usb-watch.sh` | hotplug either USB-A media port, mount + bind into the chroot as USB1 (`/media/usb1/sda1`), notify rbp via `/tmp/udev_usb1`; retries until rbp opens `export.pdb`. Also consumes `/tmp/usb-eject.req` and hands off to `usb-eject.sh`. |
| `usb-eject.sh` | safe eject of **all** USB mass-storage `sdX` devices: stop the watcher, notify rbp, unmount (incl. the chroot bind), `sync`, sysfs `device/delete`, restart the watcher. `--shutdown` skips the restart. |
| `rbp-shutdown.sh` | graceful teardown for the power hook: `stop-rbp`, `usb-eject.sh --shutdown`, release the chroot binds, `sync`. Never calls `poweroff`/`reboot`. |
| `poweroff-hook.c` | builds `poweroff-hook.so` (armhf), `LD_PRELOAD`ed into `az01-pwrbtn`; runs `rbp-shutdown.sh` before the daemon's real `reboot()` syscall. |

Source selection on the Mixstream (no hardware SOURCE button): push **Browse**
with no source selected to open rbp's SOURCE menu, push again to select USB1;
**SoundSwitch** also opens SOURCE. **SHIFT + SoundSwitch** is the safe USB
eject gesture. Implemented in `knobshim2.c`, see
[docs/10](../../docs/10-usb.md) and
[docs/15](../../docs/15-nh08s-power-and-eject.md).

Also needed on the device:

* `/data/timeout` — build it from [`timeout.c`](timeout.c) with
  `make CROSS=arm-linux-gnueabihf-` in this directory; used by `usb-watch.sh`
  and `usb-eject.sh` so a FIFO write to a dead rbp can never block.
* `/data/usb-eject.sh`, `/data/rbp-shutdown.sh` and
  `/data/poweroff-hook.so` — the eject/power helpers (not inside the chroot
  tarball). `start-rb.sh` installs the runtime `az01-power-button.service`
  drop-in only when these exist.
* `/data/rbp-audio`, `/data/knobshim2.so`, `/data/audioshim.so`,
  `/data/fbshim-tsc.so`, `/data/libdirectfb_fbdev-rot16.so` — the runtime files
  `start-rb.sh` copies into the chroot (already baked into the chroot tarball).

## Notes

* The rbp launch sets `PATH=/bin:/sbin:/usr/bin:/usr/sbin` (the device default
  lacks `/bin`) and preloads `fbshim:knobshim:audioshim` (that order).
* Restarting? clear `/tmp/guard_LocalDBServer` + `/tmp/req_LocalDBServer` first
  (DeviceSQL locks) — see [docs/11](../../docs/11-runtime-launcher.md).
