# 11 — Runtime launcher

[`scripts/device/start-rb.sh`](../scripts/device/start-rb.sh) runs on the device
and is the normal way to bring up the player.

## What it does

1. `systemctl stop engine.service edisksd.service engine-guardian.service
   enginex-*` — `engine` owns the display/audio/MIDI; `edisksd` will bus-reset
   a USB drive it doesn't manage; on the Mixstream Pro Plus `engine-guardian`
   can restart Engine and the `enginex-*` units hold audio/MIDI/CPU 3. The
   extra unit names do not exist on the SC Live 4, so the stop is harmless
   there.
2. Kill stale `rbp`/`edb_streamd`. Process matching uses
   `ps -e -o pid,args`: BusyBox `ps w` on this image lists only the current
   TTY, so `ps w | awk` silently finds nothing (and the launcher then cleans
   up under a running rbp).
3. Unblank the panel (`/sys/class/graphics/fb0/blank = 0`); Engine leaves it
   in powerdown.
4. `sh /data/fix-dev.sh` — bind mounts + device stubs.
5. Copy the patched `rbp-audio` + the shims into the chroot. The crash patch
   is required on both JP21 and NH08S, so `/data/rbp-audio` must be the
   patched binary.
6. `rm -f /tmp/guard_LocalDBServer /tmp/req_LocalDBServer` — clear stale
   DeviceSQL locks (see [10](10-usb.md)).
7. Start `edb_streamd` (DeviceSQL) **before** rbp.
8. Start rbp, then `usb-watch.sh start`.

Before starting rbp, the launcher reads
`/proc/device-tree/inmusic,product-code` (and falls back to
`/proc/device-tree/compatible`) and selects the audio layout:

| Product code | Device | Channels | Master | Headphones | Speakers |
|---|---|---|---|---|---|
| `JP21` | Denon SC Live 4 | 8 | 0/1 | 4/5 | 6/7 |
| `NH08` / `NH08S` | Numark Mixstream Pro / Pro Plus | 6 | 0/1 | 2/3 | 4/5 |

The resulting launch line (order matters):

```sh
chroot /data/rbx3-run env \
  PATH=/bin:/sbin:/usr/bin:/usr/sbin \
  DFB_ROTATE=${DFB_ROTATE:-right} KNOBSHIM_PRODUCT=$PRODUCT \
  STARTUP_MUTE_MS=1500 STARTUP_FADE_MS=300 \
  AUDIO_DEVICE=$AUDIO_DEVICE AUDIO_CHANNELS=$AUDIO_CHANNELS \
  AUDIO_MASTER_OFFSET=$AUDIO_MASTER_OFFSET AUDIO_HP_OFFSET=$AUDIO_HP_OFFSET \
  AUDIO_SPEAKER_OFFSET=$AUDIO_SPEAKER_OFFSET \
  LD_PRELOAD=/usr/lib/fbshim.so:/usr/lib/knobshim.so:/usr/lib/audioshim.so \
  /lib/ld-linux.so.3 /root/pdj/rbp -a
```

* `PATH` must include `/bin` (the device default `/usr/bin:/usr/sbin` misses the
  chroot's busybox tools → rbp logs `sh: ls: not found`).
* `knobshim.so` **before** `audioshim.so` so the shared `g_speaker_gain` data
  symbol resolves.
* the Mixstream Pro Plus reports `NH08S` and uses the same NH08 codec/UCM; it
  starts with **6 channels** (master 0/1, headphones 2/3, speakers 4/5) so the
  ETA5805 speaker path is part of the PCM. See [09](09-audio.md).
* `KNOBSHIM_PRODUCT` carries the detected product code into the shim, which
  selects the JP21 (decks ch 4/5) or NH08S (decks ch 2/3) control map. Without
  it the shim falls back to `/proc/device-tree/inmusic,product-code`.
* `AUDIO_DEVICE`, `AUDIO_CHANNELS`, the three offset variables,
  `AUDIO_SPEAKERS` and `SPEAKER_GAIN` override the detected defaults and are
  forwarded into the chroot, e.g. `AUDIO_CHANNELS=6 sh /data/start-rb.sh` or
  `AUDIO_MASTER_OFFSET=2 AUDIO_HP_OFFSET=0 sh /data/start-rb.sh` if the
  master/headphone pairs are reversed. Use `AUDIO_DEVICE=hw:0,0` if the card
  index differs on the Mixstream.
* the speaker/booth level is fixed via `SPEAKER_GAIN` (see [09](09-audio.md)).

## Mixstream Pro Plus service conflicts

The Mixstream runs a pre-existing `enginex` layer. `engine.service` has a
drop-in that replaces `ExecStart` with `/data/enginex/bundle/bin/engine-ui-guard
service /usr/Engine/Scripts/runengine` and pulls in extra units. Before
starting rbp, stop all of these (not just `engine`):

```sh
systemctl stop engine.service edisksd.service \
                 engine-guardian.service \
                 enginex-rb-bridge.service \
                 enginex-stream-sync.service \
                 enginex-sc5000-deemixd.service
```

`engine-guardian` can restart Engine; `enginex-stream-sync` uses CPU 3 and an
audio analyzer. Leaving them running can steal audio/MIDI/CPU or relaunch
Engine over rbp. `edisksd` mounts USB media by label (e.g. `/media/DMBEST`)
and must be stopped so `usb-watch.sh` can own `/media/usb1/sda1`.

Before opening the 6-channel speaker path the stock UCM would configure the
ETA5805 amp, but on this unit `alsaucm -c NH08 set _verb HiFi` **fails**
(`unable to execute cset 'Input Mixer'`): the UCM targets TAS5805M controls
the ETA5805 does not expose. The launcher therefore does not call it; the amp
keeps its boot configuration and follows the physical SPEAKER knob. Card 1
exposes only `Master Playback Switch/Volume`, `DSP Volume`, `Analog Gain`.
See [09](09-audio.md).

The unit has no `amixer`/`aplay`/`alsactl`; use `alsaucm`, `aplaymidi` or a
small test tool.

## Start from SSH

Detached (survives the SSH session and keeps the launcher/watcher alive):

```sh
ssh root@mixstreamproplus.local
nohup setsid sh /data/start-rb.sh >/data/start-rb.log 2>&1 </dev/null &
```

Or foreground (the SSH session stays attached while rbp runs):

```sh
ssh root@mixstreamproplus.local
sh /data/start-rb.sh
```

Check / stop:

```sh
ps -e -o pid,args | grep '[r]oot/pdj/[r]bp'
tail -n 20 /data/start-rb.log
tail -f /data/rbp-p.log          # rbp stderr

sh /data/usb-watch.sh stop
pkill -9 ld-linux.so.3           # kills rbp + edb_streamd (matches comm, not -f)
pkill aseqdump                   # if a raw MIDI capture is running
```

`pkill -f` would also match the SSH shell's own command line, so use the
plain `pkill` form (process name).

Restart in one go (detached, ready in ~20 s):

```sh
sh /data/usb-watch.sh stop 2>/dev/null
pkill -9 ld-linux.so.3 2>/dev/null
rm -f /tmp/guard_LocalDBServer /tmp/req_LocalDBServer
sleep 2
nohup setsid sh /data/start-rb.sh >/data/start-rb.log 2>&1 </dev/null &
```

Or use the deployed helpers:

```sh
sh /data/stop-rbp                    # stop rbp, edb_streamd, USB watcher, capture
sh /data/start-rbp-debug.sh          # detached + verbose + aseqdump capture
sh /data/stop-rbp-return-engine.sh   # stop rbp and restart Engine OS
```

`start-rbp-debug.sh` passes environment overrides through, logs to
`/data/start-rb.log`, `/data/rbp-p.log`, `/tmp/knobshim.log`,
`/tmp/audioshim.log` and `/tmp/seqdump.log` (touch events appear in
`/data/rbp-p.log` via `FBSHIM_DEBUG=1`), and restarts rbp if it is already
running (`start-rb.sh` kills stale players first). Their sources are
`scripts/device/{start-rbp-debug.sh,stop-rbp,stop-rbp-return-engine.sh}`.

`start-rb.sh` already removes the DeviceSQL locks (`/tmp/guard_LocalDBServer`,
`/tmp/req_LocalDBServer`), so the `rm` is only needed if you stop rbp without
using the launcher — without it the USB library can show the generic "USB1"
label instead of the volume name/track count. Wait for
`RBP=<pid> ready (udev_usb1 fd opened)` in `/data/start-rb.log` before
touching the panel.

`start-rb.sh` defaults to `DFB_ROTATE=right` on the Mixstream (the panel is
upside down with `left`); override per run with
`DFB_ROTATE=left sh /data/start-rb.sh`. The launcher stops
`engine`/`edisksd`/`engine-guardian`/`enginex-*` itself.

## Restore Engine OS

```sh
sh /data/usb-watch.sh stop 2>/dev/null
pkill -9 ld-linux.so.3 2>/dev/null
systemctl reset-failed engine.service
systemctl start engine.service
# Mixstream Pro Plus: the enginex units are pulled in by engine.service's
# drop-in, but start them explicitly if a manual stop left them down:
systemctl start edisksd.service enginex-rb-bridge.service \
                enginex-stream-sync.service enginex-sc5000-deemixd.service
```

## Autostart

There is no shipped autostart unit. A systemd unit under the `/etc` overlay
(`/data/system/etc/overlay/systemd/system/rb.service` + a
`multi-user.target.wants` symlink) can stop `engine` and run `start-rb.sh` at
boot; make it reversible (`systemctl stop rb; systemctl start engine`).
