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
we deliberately leave that timing unchanged. A separate plan for a much shorter,
tap-to-shutdown path in rbp is recorded in [section 8](#8-plan-1-s-graceful-shutdown-not-implemented).

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

For one-button start, also deploy `/data/soundswitch-rbp.sh` and install the
boot hook as described in [section 4](#4-one-button-start-soundswitch--rbp).

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

## 4. One-button start (SoundSwitch → rbp)

For SSH-free use, the stock `soundswitch.service` can be repurposed so the
physical **SoundSwitch** button in Engine OS starts rbp instead. This was
verified on the Mixstream Pro Plus: pressing SoundSwitch in Engine starts
`soundswitch.service` and runs `/usr/SoundSwitch/Scripts/runSoundSwitch`.

`/etc` cannot hold a drop-in on this firmware: root is dm-verity protected
(`root=/dev/dm-0 ro`, `/sys/block/dm-0/ro = 1`), and even
`mount -o remount,rw /` fails. The override is therefore a **runtime** drop-in:

```
/run/systemd/system/soundswitch.service.d/50-soundswitch-rbp.conf
```

```ini
[Service]
Type=simple
ExecStart=
ExecStart=/bin/sh /data/soundswitch-rbp.sh
ExecStopPost=
PIDFile=
Restart=no
TimeoutStopSec=30
```

* `ExecStart=` clears the original SoundSwitch launch.
* `Type=simple` replaces `Type=forking`: `/data/start-rb.sh` stays in the
  foreground while rbp is alive, so the service remains active for the whole
  session and becomes inactive after `sh /data/stop-rbp`.
* `PIDFile=` and `ExecStopPost=` are cleared because the old
  `/tmp/soundswitch.pid` and cleanup script are no longer relevant.
* `Restart=no` stops systemd from relaunching rbp after it exits.

`/data/soundswitch-rbp.sh` logs the trigger to `/data/soundswitch-rbp.log` and
`exec sh /data/start-rb.sh`. The original
`/etc/systemd/system/soundswitch.service` is never edited.

### Persistent boot hook

Because `/run` is cleared at boot, `/data/install-soundswitch-hook.sh` inserts a
marker-bounded block into `/data/enginex/bundle/boot-activate.sh`. That is the
only writable boot activator found on this firmware, and it already recreates
the other `/run/systemd/system/*.service.d` drop-ins. The added block checks
that `/data/soundswitch-rbp.sh` exists, writes the runtime override, and runs
`systemctl daemon-reload` on every full boot activation.

The block must be placed **before** `boot-activate.sh`'s final
`systemctl restart engine.service`. An earlier version appended it at EOF; on
reboot that Engine restart terminated the activation process before the hook
ran, so the runtime drop-in was missing and SoundSwitch opened the stock app.
The helper now relocates old EOF copies to the correct position.

The hook is guarded by `/data/soundswitch-rbp.disable`: when that file exists,
the block removes the runtime drop-in and stock SoundSwitch behaviour is left
alone.

Install or refresh the hook:

```sh
scp scripts/device/install-soundswitch-hook.sh \
    root@<device>:/data/install-soundswitch-hook.sh
ssh root@<device> 'chmod 755 /data/install-soundswitch-hook.sh &&
                   sh /data/install-soundswitch-hook.sh'
```

The helper is idempotent. Before changing `boot-activate.sh` it saves a
timestamped copy as
`/data/enginex/bundle/boot-activate.sh.pre-soundswitch-rbp.<YYYYmmddHHMMSS>`.
It also applies the runtime drop-in immediately, so no reboot is needed.

**After any enginex update or reinstall**, `boot-activate.sh` is replaced and
the marker block is lost. Re-run:

```sh
sh /data/install-soundswitch-hook.sh
```

If enginex was reinstalled from scratch, re-copy `/data/soundswitch-rbp.sh`
before running the helper. Verify with:

```sh
systemctl cat soundswitch.service
systemctl show soundswitch.service -p Type -p ExecStart -p ExecStopPost \
    -p PIDFile -p Restart -p TimeoutStopSec
```

Rollback:

```sh
touch /data/soundswitch-rbp.disable
sh /data/install-soundswitch-hook.sh
```

That removes the runtime drop-in immediately and makes future boots skip it. To
remove the boot-hook code itself, restore the saved `boot-activate.sh` backup
(or delete the lines between `# >>> nh08s-one-button-rbp >>>` and
`# <<< nh08s-one-button-rbp <<<`), then run `systemctl daemon-reload`.

This is a deliberate replacement of the SoundSwitch shortcut/menu in Engine OS.
Plain SoundSwitch **inside rbp** still maps to rbp's SOURCE key — only the
Engine OS trigger is hijacked.

## 5. Verify

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

## 6. Troubleshooting

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
| SoundSwitch starts SoundSwitch instead of rbp | runtime drop-in missing, or the enginex boot hook was not reapplied | run `sh /data/install-soundswitch-hook.sh`; check `systemctl cat soundswitch.service` and `/data/soundswitch-rbp.log` |
| SoundSwitch starts SoundSwitch again after an enginex update | the update replaced `boot-activate.sh` and removed the marker block | re-copy `scripts/device/install-soundswitch-hook.sh` if needed, then run `sh /data/install-soundswitch-hook.sh` |
| SoundSwitch works until reboot, then opens the stock app again | the boot hook was appended after the final `systemctl restart engine.service` and never ran | re-run `sh /data/install-soundswitch-hook.sh`; it relocates the block before that restart |
| SoundSwitch does nothing in Engine | the button did not call `soundswitch.service`, or `/data/soundswitch-rbp.disable` exists | check `journalctl -u soundswitch.service` and `ls -l /data/soundswitch-rbp.disable`; re-verify the trigger before changing the hook |
| SoundSwitch stops responding after the app was stopped manually over SSH | Engine still believes the SoundSwitch backend is open | return to a clean Engine state with `sh /data/stop-rbp-return-engine.sh` (or restart `engine.service`), then press once again |
| rbp starts but Wi-Fi/SSH disappears during the session | observed once after a fresh boot; cause not yet confirmed | rbp keeps running; hold power ~6 s for the normal graceful teardown and reboot, then inspect `/data/soundswitch-rbp.log`, `/data/start-rb.log` and `/data/rbp-shutdown.log` |
| rbp exits/crashes during a test | no crash evidence is kept by the normal launcher; `/tmp` is tmpfs and shim logs are deleted on the next start | reproduce with `sh /data/start-rb-crashdiag.sh`, then inspect `/data/rbp-diag/<timestamp>/crash.log` and the archived shim/rbp logs; report before power-cycling |

## 7. Files and logs

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
| `/data/soundswitch-rbp.sh` | one-button start wrapper (`exec sh /data/start-rb.sh`) |
| `/data/soundswitch-rbp.log` | log of SoundSwitch → rbp triggers |
| `/data/install-soundswitch-hook.sh` | idempotent helper that patches the enginex boot activator and reapplies the runtime drop-in |
| `/run/systemd/system/soundswitch.service.d/50-soundswitch-rbp.conf` | runtime drop-in that hijacks the Engine OS SoundSwitch trigger |
| `/data/enginex/bundle/boot-activate.sh` | patched boot activator; marker `nh08s-one-button-rbp` recreates the drop-in each boot |
| `/data/enginex/bundle/boot-activate.sh.pre-soundswitch-rbp.<timestamp>` | backup made before patching `boot-activate.sh` |
| `/data/soundswitch-rbp.disable` | optional flag: skip/remove the one-button hook |
| `/data/start-rb-crashdiag.sh` | diagnostic launcher: adds `crashcatch.so`, keeps the power hook and `USBSTOP_*`, archives logs to `/data/rbp-diag/<timestamp>/` |
| `/data/rbp-diag/` | crash-diagnostic archives; `previous/` keeps the prior session's logs before the next start overwrites them |

## 8. Plan: 1 s graceful shutdown (not implemented)

Decision: while **rbp** is running, a brief power-button tap should start the
existing graceful shutdown immediately. Engine OS keeps the stock ~6 s
long-press. "Immediate" means the teardown starts within milliseconds; USB
eject, unmount and `sync` still run before power is cut. Instant power-off
without teardown is deliberately rejected.

### Evidence

`/dev/input/by-path/platform-gpio-keys-event` is a gpio-keys evdev device whose
modalias contains `k74` (`KEY_POWER`). Disassembly of `/usr/bin/az01-pwrbtn`
shows:

1. it opens that evdev device and sets its timestamps to `CLOCK_MONOTONIC`;
2. on a `KEY_POWER` press it stores the **event timestamp** as the start time;
3. in its loop it calls `__clock_gettime64(CLOCK_MONOTONIC, ...)` for the
   current time;
4. it compares `now - start` with `0x5B8D7F` = **5,999,999 µs**;
5. on timeout it calls `sync()` and `reboot(RB_POWER_OFF)`.

The existing `poweroff-hook.so` already intercepts that `reboot()` and runs
`/data/rbp-shutdown.sh` before the real raw reboot.

### Proposed implementation

Extend `scripts/device/poweroff-hook.c` with a second interposer:

```c
int __clock_gettime64(clockid_t clk, struct rbp_timespec64 *tp)
{
    int rc = real_clock_gettime64(clk, tp);

    if (rc == 0 && clk == CLOCK_MONOTONIC &&
        access("/data/power-immediate.disable", F_OK) != 0)
        tp->tv_sec += 10;

    return rc;
}
```

`real_clock_gettime64` is resolved with `dlsym(RTLD_NEXT, "__clock_gettime64")`.
On 32-bit ARM the time64 structure is **not** `struct timespec`: it is a 64-bit
`tv_sec`, a 32-bit `tv_nsec` and 32 bits of padding, so a private matching
structure must be used.

Because the daemon takes the press-start time from the kernel event but the
current time from libc, adding 10 s to libc's monotonic reading makes the very
first elapsed-time check pass the stock 6 s threshold. The stock daemon then
calls `reboot()` and our existing hook performs the normal graceful teardown.

No `start-rb.sh` change is required: the hook is already only preloaded while
rbp is running. `/data/power-immediate.disable` gives instant rollback.

### Files to change

* `scripts/device/poweroff-hook.c` — add the clock interposer and disable flag.
* `scripts/device/README.md` — document the new hook behaviour.
* `docs/15-nh08s-power-and-eject.md` — this section becomes the implementation
  record.
* `work/mixstream-pro-plus.patch` — regenerate and apply-check.

### Deployment and verification

1. Ask before deploying.
2. Back up `/data/poweroff-hook.so`, rebuild with
   `make -C scripts/device CROSS=arm-linux-gnueabihf- poweroff-hook.so`,
   verify symbols/versions and hash, then copy it to `/data`.
3. Restart only `az01-power-button.service` so the daemon maps the new `.so`.
   No device reboot is needed.
4. Check `systemctl cat az01-power-button.service` still shows the `LD_PRELOAD`
   drop-in and `/proc/$(pgrep -x az01-pwrbtn)/maps` contains
   `/data/poweroff-hook.so`.
5. Ask before the hardware test. A short tap should produce a fresh
   `=== shutdown requested ===` in `/data/rbp-shutdown.log` within milliseconds,
   followed by the normal teardown and power-off. Inspect the log after the
   device boots again.

### Rollback and risk

```sh
touch /data/power-immediate.disable
```

The hook reads the flag on each clock call, so rollback takes effect
immediately. If `dlsym` fails, the override returns the real time unchanged and
the stock ~6 s long-press remains. Main risk: reliance on the daemon's imported
glibc-internal `__clock_gettime64` symbol; the stock binary is fixed by
dm-verity on this firmware, and failure is fail-safe.
