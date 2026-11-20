# 05 — Soft-float chroot on the SC Live 4

`rbp` runs from `/data/rbx3-run`, a soft-float glibc-2.13 RX3 userland.
`/data` has ~5.6 GB free, so no trimming is needed.

## Build (host, WSL/Linux)

[`scripts/build-chroot.sh`](../scripts/build-chroot.sh) assembles the whole
tree and tars it to `work/rbx3-run.tgz`:

1. **RX3 rootfs** (`extracted/XDJRX3-rootfs`) — soft-float glibc 2.13,
   libstdc++, DirectFB, freetype, ALSA, `edb_streamd`, busybox.
2. **GUI assets** → `root/gui/{fontdata,imagedata,pset,system}` (rbp reads
   `/root/gui/pset/...` and `/root/gui/system/...`).
3. **Patched player** → `root/pdj/rbp` (shared rbp patches + the SC Live 4
   `getPcController` fix — see [`scripts/patch-rbp-sclive4.py`](../scripts/patch-rbp-sclive4.py)).
4. **Shims** → `usr/lib/{fbshim,knobshim,audioshim,crashcatch}.so`.
5. **DirectFB 1.4.16 stack** — core libs + the patched rot16 fbdev module +
   inputdrivers/wm, in `usr/lib/directfb-1.4-6/`. The RX3 `/lib` is a real
   directory (not usrmerged), while DirectFB looks for modules under
   `/lib/directfb-1.4-6`; the build adds
   `/lib/directfb-1.4-6 → /usr/lib/directfb-1.4-6` (and `-1.4-0`). Without
   them `DirectFBCreate()` fails (`dfb_core_create ret=17`) and rbp crashes
   in its display driver.
6. **`usr/etc/directfbrc`** (`no-hardware`/`no-cursor`/`system=fbdev`/
   `fbdev=/dev/fb0`) and **`root/settings/TouchCalib_{User,Factory}.dat`**.
7. Fixes exec bits and the `etc/mtab → /proc/mounts` symlink.

Asset locations are taken from `RX3` / `CHROMEBIT` (defaults `$HOME/xdjrx3-findings`
and `$HOME/chromebit`); the output goes to `work/`.

```sh
RX3=/path/to/xdjrx3-findings scripts/build-chroot.sh   # -> work/rbx3-run.tgz
```

**Always rebuild the tarball after changing a shim.** The tarball bundles the
compiled `.so` files from `scripts/shims/`, not the sources. `build-chroot.sh`
rebuilds them automatically when a `.c` or the `Makefile` is newer than the
corresponding `.so`, but a tarball built earlier keeps stale shims; deploying
one makes a shim fix appear to have no effect. Check before deploying:

```sh
make -C scripts/shims RX3=... check
stat -c '%y %n' scripts/shims/*.c scripts/shims/*.so work/rbx3-run.tgz
```

## Deploy

The device's busybox `tar` has **no `-z`**, so decompress with `zcat`.

> **Unmount the chroot binds before deleting the tree.** `/data/rbx3-run/dev`
> is a bind mount of the host `/dev`. `rm -rf /data/rbx3-run` while it is
> mounted deletes the device's real device nodes: `/dev/null` becomes a plain
> file, `/dev/urandom` disappears and **sshd resets every new connection**
> (needs a reboot to recover). `fix-dev.sh` now refuses to continue if a bind
> is still mounted, but the deploy command must unmount too.

```sh
scp work/rbx3-run.tgz root@sclive4:/data/
ssh root@sclive4 '
  sh /data/stop-rbp
  for m in dev proc sys tmp; do
    mountpoint -q /data/rbx3-run/$m && umount /data/rbx3-run/$m
    mountpoint -q /data/rbx3-run/$m && { echo "$m still mounted" >&2; exit 1; }
  done
  rm -rf /data/rbx3-run.new; mkdir -p /data/rbx3-run.new
  zcat /data/rbx3-run.tgz | tar x -C /data/rbx3-run.new
  rm -rf /data/rbx3-run
  mv /data/rbx3-run.new /data/rbx3-run
  chown -R root:root /data/rbx3-run
  sh /data/fix-dev.sh'
```

`fix-dev.sh` creates the bind mounts (`/dev /proc /sys /tmp`), the device
stubs (gpiodrv, subucom FIFOs, hidg0, printkdrv0, `chmod 000 /dev/mem`),
the `/tmp/udev_*` FIFOs and the `etc/mtab` symlink. It must run after every
reboot.

## Notes

* the build script restores exec bits on `/bin`, `/sbin`, `/usr/bin`,
  `/usr/sbin` and the loader.
* `var/log/wtmp` may have an ACL that denies even root on a Windows/WSL mount;
  the script uses `tar --ignore-failed-read` and recreates it empty.
* Symlinks survive (git-bash/WSL store real reparse points).
* Verify with `chroot /data/rbx3-run /bin/sh -c 'echo ok'`.
