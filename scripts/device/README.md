# scripts/device/

On-device scripts (ship to `/data/` on the SC Live 4 or Mixstream Pro / Pro Plus).

| Script | Purpose |
|---|---|
| `fix-dev.sh` | bind mounts (`/dev /proc /sys /tmp`), device stubs, `/tmp/udev_*` FIFOs, `etc/mtab` symlink. Run after every reboot. |
| `start-rb.sh` | stop Engine OS + `edisksd`, prepare the chroot, select the JP21/NH08 audio layout from the device tree, start `edb_streamd` then `rbp`, start the USB watcher. |
| `start-rbp-debug.sh` | same, but detached with `KNOB_VERBOSE=1` + `FBSHIM_DEBUG=1` and an `aseqdump` raw-MIDI capture; logs go to `/tmp/{knobshim,audioshim,seqdump}.log` and touch events to `/data/rbp-p.log`. Re-running restarts rbp. |
| `stop-rbp` | stop rbp + `edb_streamd` + the USB watcher (panel keeps the last frame; Engine is **not** restarted). |
| `stop-rbp-return-engine.sh` | `stop-rbp`, then `reset-failed` + start `engine.service` and the `edisksd`/`enginex-*` units. |
| `usb-watch.sh` | hotplug either USB-A media port, mount + bind into the chroot as USB1 (`/media/usb1/sda1`), notify rbp via `/tmp/udev_usb1`; retries until rbp opens `export.pdb`. |

Source selection on the Mixstream (no hardware SOURCE button): push **Browse**
with no source selected to open rbp's SOURCE menu, push again to select USB1;
**SoundSwitch** also opens SOURCE. Implemented in `knobshim2.c`, see
[docs/10](../../docs/10-usb.md).

Also needed on the device:

* `/data/timeout` — build it from [`timeout.c`](timeout.c) with
  `make CROSS=arm-linux-gnueabihf-` in this directory; used by `usb-watch.sh`
  so a FIFO write to a dead rbp can never block the watcher.
* `/data/rbp-audio`, `/data/knobshim2.so`, `/data/audioshim.so`,
  `/data/fbshim-tsc.so`, `/data/libdirectfb_fbdev-rot16.so` — the runtime files
  `start-rb.sh` copies into the chroot (already baked into the chroot tarball).

## Notes

* The rbp launch sets `PATH=/bin:/sbin:/usr/bin:/usr/sbin` (the device default
  lacks `/bin`) and preloads `fbshim:knobshim:audioshim` (that order).
* Restarting? clear `/tmp/guard_LocalDBServer` + `/tmp/req_LocalDBServer` first
  (DeviceSQL locks) — see [docs/11](../../docs/11-runtime-launcher.md).
