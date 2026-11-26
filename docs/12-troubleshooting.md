# 12 — Troubleshooting

Symptom → cause → fix.

## Display / boot

| Symptom | Cause | Fix |
|---|---|---|
| Kernel **oops/reboot** as soon as rbp starts | `directfbrc` missing → DirectFB takes the GPU/dri path (`panic_on_oops=1`) | install `usr/etc/directfbrc` with `no-hardware` ([06](06-display.md)) |
| UI sideways or upside down | wrong `DFB_ROTATE` | SC Live 4: `left`; Mixstream Pro Plus: `right` (measured; `left` is 180° off) ([06](06-display.md)) |
| `EINVAL` on `FBIOPUT_VSCREENINFO` | 16 bpp modeset on the fixed 32 bpp DRM fb | use the patched fbdev module |
| rbp crashes in `DS_HW_Glib3_DFB.c` (`addr=0x30`), `dfb_core_create ret=17` | DirectFB cannot find `/lib/directfb-1.4-6` (RX3 `/lib` is not merged with `/usr/lib`) | add the `/lib/directfb-1.4-6 → /usr/lib/directfb-1.4-6` links ([06](06-display.md)) |
| rbp exits during display init, `fb0/blank=4` | Engine left the panel in powerdown | `echo 0 > /sys/class/graphics/fb0/blank` before launch ([06](06-display.md)) |

## Startup / controls

| Symptom | Cause | Fix |
|---|---|---|
| rbp exits ~1 s after start, `crash.log` shows `pc=0x0031df70 addr=0x9c` | `getPcController()` NULL deref — **also on NH08S** | apply `scripts/patch-rbp-sclive4.py` and ship the patched binary as `/data/rbp-audio` ([03](03-port-plan.md)) |
| `sh: ls: not found` in `rbp-p.log` | chroot launched without `/bin` in `PATH` | set `PATH=/bin:/sbin:/usr/bin:/usr/sbin` |
| PLAY/CUE do nothing on Mixstream | shim still mapped the SC Live 4 deck channels | decks are ch **2/3** on NH08S; `knobshim2.c` detects the product and remaps (fixed) ([14](14-mixstream-pro-plus-survey.md)) |
| Jog wheel does nothing on Mixstream | SC Live 4 jog CCs still in use | NH08S jog is CC **0x37/0x4D**, detected from the product code ([13](13-mixstream-pro-plus-roadmap.md)) |
| VU meters do not move on Mixstream | JP21 bitwise values were sent to the mixer strips (ch0 CC32 / ch1 CC33) | the NH08S panel is a **stereo main** pair on **ch15** CC32/CC33 with incremental `[0,14,27,40,53,66]` (5 LEDs); shim now sends master L/R ([08](08-controls.md)) |
| Only 3 of the 5 VU LEDs ever light | JP21 6-LED thresholds rescaled 6→5 | NH08S thresholds `-35/-25/-21/-15/-10 dBFS` (top step lowered from the QML `-3`, since rbp peaks ~-8 dBFS at full master) on the post-Main-Vol peak; calibrate with `VU_OFFSET_DB` ([08](08-controls.md)) |
| VU meters feel sluggish / over-sensitive | envelope release was fixed at `0.995`/block (~300 ms) and the raw QML scale read hot | `VU_RELEASE` (default `0.98`, ~70 ms) in `audioshim.so`; `VU_OFFSET_DB` (default `0`) ([08](08-controls.md)) |
| VU LEDs stay lit with the master knob at zero | the shim fell back to rbp's **pre**-Main-Vol mono meter whenever the post-gain peak was 0 | fallback removed; only audioshim's post-Main-Vol peaks drive the LEDs ([08](08-controls.md)) |
| NH08S VU ignores the master knob / both strips identical | the shim divided out Main Vol and merged rbp's mono master meter into both sides | post-Main-Vol peaks per side are the only source; rbp's pre-main mono meter is not used ([08](08-controls.md)) |
| Pitch bend **+** does not toggle master tempo | note 30 needed deck-scoped `0x4108` and a press-only event | `handle_note()` maps NH08S notes 29/30 to TEMPO RANGE/MT on deck 1/2, reaching `onKey_MasterTempo` ([08](08-controls.md)) |
| Quantize stays on (Mixstream has no QUANTIZE key) | rbp's engine state is inherited from the RX3 | `nh08s_quantize_off()` forces deck 1/2 + Beat FX quantize off for the first 30 s ([08](08-controls.md)) |
| Settings button opens rbp's menu but SHIFT + Settings does nothing | the Settings key is global note 7, while Shift is the per-deck note 28 | `handle_note()` sends `0x0206` K_MENU normally and `0x0210` K_SHORTCUT while Shift is held ([08](08-controls.md)) |
| FX select LEDs are all dark on the Mixstream | rbp's `StatWatcher` is null before initialisation, or the selector position is one of the 10 without a button | the shim mirrors byte `+0xa` (`g_ui → +0x38 → +0x1c`); positions 0/1/6/9 light Delay/Echo/Flanger/Trans and everything else is deliberately off ([08](08-controls.md)) |
| Deck FX paddle no longer moves Beat FX to that deck | by design: the paddle toggles the effect on/off but never changes the channel | Beat FX starts on **MASTER**; use SHIFT + DELAY (ch1) / SHIFT + PHASER (ch2) ([08](08-controls.md)) |
| SHIFT + SYNC does nothing (or just syncs) | Shift is the per-deck note 28 and must be down *before* SYNC | hold deck Shift, then press SYNC → `0x4111` K_MASTER; the release is swallowed so no `K_SYNC` is sent ([08](08-controls.md)) |
| SHIFT + pitch bend + does not switch quantize back off | older shim builds were enable-only | SHIFT + pitch bend + now **toggles** `0x410b` per deck (ch2 = deck 1, ch3 = deck 2); pressing again turns it off ([08](08-controls.md)) |
| Pitch fader works backwards on Mixstream | JP21 formula assumes `invert: true`; the NH08S QML has no invert | `handle_pitch()` negates for NH08S; top = faster ([08](08-controls.md)) |
| Jog feels wrong on Mixstream (too fast, or slow / inert after the PPR fix) | rev/s comes from the panel's counts/rev, while rbp drives scratch and seek from the position counter | NH08S sends a **3600-pulse revolution** (`JOG_OUT_PPR`; `JogPulse` = 12.25 samples/pulse) and multiplies the speed by `JOG_SPEED_GAIN=1.5` (rbp bends only above 0.5 rev/s). `JOG_PPR=1638` is the panel's hardware counts/rev. Also make sure `JOG_VERBOSE` is off — per-event logging stalls the wheel ([08](08-controls.md)) |
| Sweep FX knob does nothing on Mixstream | Filter select sent before rbp's mixer exists, so it is dropped | shim re-asserts `K_FILTER` for 30 s and seeds 50 % until CC11 arrives ([08](08-controls.md)) |
| rbp starts, then Engine comes back | `engine-guardian` / `enginex-*` still running | stop those units before rbp ([11](11-runtime-launcher.md)) |
| rbp runs ~15 s, then launcher exits and kills it | BusyBox `ps w` lists only the current TTY, so `awk` never finds rbp | use `ps -e -o pid,args` in launcher/watcher ([11](11-runtime-launcher.md)) |
| A shim fix has no effect after deploy | stale `work/rbx3-run.tgz` built before the shim change | rebuild with `scripts/build-chroot.sh` and verify the `.so` timestamps ([05](05-chroot.md)) |
| **sshd resets every connection** (`kex_exchange_identification: Connection reset`), host still answers ping | the chroot `/dev` bind mount was deleted through (`rm -rf /data/rbx3-run` while `/data/rbx3-run/dev` was a bind of the host `/dev`), so `/dev/null`, `/dev/urandom`, `/dev/fb0`, `/dev/input/*` are gone | power-cycle the device — a fresh boot repopulates devtmpfs. Then deploy with the unmount-first recipe ([05](05-chroot.md)) |
| Faders/EQs dead, PLAY works | absolute controls sent as `OP_ROTATE` | send `OP_VALUE` for fader/trim/EQ/xfader ([08](08-controls.md)) |
| Taps do nothing | `TouchCalib_User.dat` missing/wrong | install identity calib ([07](07-touch.md)) |
| Taps do nothing only on some boots | touch evdev number changed (`event0` = `gpio-keys`) | `fbshim-tsc.so` resolves ILI2117 by by-path/name; hard-coded event0 is the bug ([07](07-touch.md)) |
| Stick inserted but rbp shows no USB source; dmesg spams `FAT-fs (sda1): Directory bread(…) failed` | `/media/usb1/sda1` is a **stale mount** of a stick that was pulled (or a watcher restart lost track of it); the new stick enumerated as `sdb1` and `attach()` skipped it as "already mounted" | `usb-watch.sh` now compares the mount source with the current partition and remounts (`stale … remounting`), and detaches a stale mount when no media device is present ([10](10-usb.md)); `sh /data/usb-watch.sh stop; start` re-runs the check |
| Touch taps land mirrored/rotated | `DFB_ROTATE` does not match the panel orientation | set `DFB_ROTATE=right` on the Mixstream, `left` on the SC Live 4; the shim derives the flip from it ([07](07-touch.md)) |
| Stick mounts but there is no way to select it (Mixstream) | rbp's SOURCE menu needs the RX3 hardware key; the Mixstream has none | push **Browse** with no source selected, then push again to pick USB1; **SoundSwitch** also opens SOURCE ([10](10-usb.md)) |

## Pads (NH08S)

| Symptom | Cause | Fix |
|---|---|---|
| rbp SIGSEGV in `led_thread()` when a pad mode changes (`CRASH pc=0xb6e795fc addr=0x00003161`) | pad-mode reader dereferenced `StatWatcher + 0x1c` as if it were the watcher; it is the MixBeatFx sub-struct | read `g_ui → +0x38 → StatWatcher`, then deck pointer at `+0x0c`/`+0x10` and the mode byte at `+0x281` ([08](08-controls.md)) |
| Pad-mode LEDs / SHIFT pads wrong right after load | `PlayerInnards::getStat()` encodes mode as base **+4** when an extended flag is set (`+0x79..+0x7c` → 4..7), so `mode == 0..3` comparisons fail | mask the byte with `&3` in `nh08s_pad_mode()` ([08](08-controls.md)) |
| SHIFT + pad does not delete a hot cue | `(1<<16)|keycode` only stores the low 16 bits in `IKeyInput+0x8`, so rbp never sees SHIFT | send `0x4103` press/release on the deck channel while note 28 is held; `sendKey()`'s `isPressed(0x4103, ch)` makes `pad_HotCue()` clear the cue ([08](08-controls.md)) |
| All four pads dark / wrong in HOT CUE mode | rbp's `LedStat` ids 18–25 were not mirrored, or the panel needs `LedType.Simple` velocities | use Note On `0x7f` / Note Off `0x00`, state 2 = blink ([08](08-controls.md)) |

## Beat sync / audio-thread crashes

### SIGSEGV in `playengine::BeatSync::checkPrecision()` (NH08S, 2026-11-26 12:06 UTC)

- Core: `/media/usb1/sda1/JuceALSA.2026-11-26T120600Z.core.zst` (plus `.metadata` and `.log.zst`), PID 832, `signal=11`.
- Stack: `djengine::DjEngineIF::audioDeviceIOCallback` → `playengine::SyncMgr::sync` → `BeatSync::checkAllPrecision` → `checkPrecision`; fault at `0x7c404`, `ldr r2, [r3, #0x24]` with `r3 = 0`.
- `BeatSync` keeps two 88-byte `BeatSyncInfo` records: `+0` is `Player*`, `+4` is the cached `Player::getBeatPosInfo()` pointer. Deck 1's pointer is valid; deck 2's is NULL.
- Deck 2 also has `Player::readerOwner.reader == NULL` (deck 1's is valid). `getBeatPosInfo()` returns `reader->beatPos` via `ReaderOwner +4` then `+0x69c`, so with no loaded reader it returns NULL.
- `BeatSync::duplicateMaster()` (`0x7ca08`) stores that NULL at `BeatSyncInfo[1]+4` and still arms the precision path; the audio thread dereferences it on the next callback.
- Timing: USB detach/attach and `export.pdb` reopen at 12:05:01–12:05:34, then SOURCE/BACK/BROWSE and deck-2 PLAY (`0x4101`) immediately before the crash. Earlier USB-only sessions without deck-2 PLAY did not crash.
- The function is byte-identical to stock `extracted/rbp-audio`; this is **not** caused by our rbp patch, the shims, or the DirectFB/fbdev work.

**Minimal fix (crash suppression):** a NULL guard on the four `ldr ..., [BeatPosInfo, #0x24]` sites — `checkPrecision()` at `0x7c310` / `0x7c404` and `calcBeatDifference()` at `0x7d3a4` / `0x7d484`. A 24-byte ARM code cave checks the pointer and sets the loaded value to 0, letting the existing `cmp ..., #0` path skip the precision correction. This stops the SIGSEGV but leaves the stale sync state, so the correction is silently skipped.

**Root-cause fix (preferred):** in `duplicateMaster()` (`0x7caa8`, `0x7cc78`, `0x7ccf4`) make the cached `getBeatPosInfo()` stores conditional so a NULL pointer is never written to `BeatSyncInfo+4`. The optional patch combines this with the NULL-safe cave above, so an already-armed `+25`/`+49` precision gate cannot crash the audio thread even if the pointer was left NULL by another path. `syncBeat()`'s own dereferences (`0x7b4ac`, `0x7b558`, `0x7b570`, `0x7b6a4`) are already behind a reader-ready check.

Both changes are implemented in `tools/patch-rbp/rbp_patch.py` behind the opt-in flag `--fix-beat-sync-null`; they are **not** part of the standard build. No patched binary has been built or deployed; rbp was restarted unchanged for further observation.

## USB

| Symptom | Cause | Fix |
|---|---|---|
| Stick never detected | `usb-watch.sh` not running, or wrong bus | SC Live 4 media port is **usb1** (`USBWATCH_BUSES="1 2 3"`) ([10](10-usb.md)) |
| Generic "USB1", 0 tracks after a restart | stale DeviceSQL guard/req locks | `rm -f /tmp/guard_LocalDBServer /tmp/req_LocalDBServer`, then re-notify ([10](10-usb.md)) |
| Stick ejects after ~30 s | `edisksd.service` running | stop it in the launcher |
| SHIFT + SoundSwitch does nothing | SHIFT not held first, or the eject latch is still set | hold deck SHIFT, then press SoundSwitch; watch `/tmp/knobshim.log` with `KNOB_VERBOSE=1` ([15](15-nh08s-power-and-eject.md)) |
| Only one deck stops on eject | parallel `UsbStop 0x8002` burst coalesced in rbp | restart rbp with `USBSTOP_SEQUENTIAL=1` (`USBSTOP_GAP_MS` to tune) ([15](15-nh08s-power-and-eject.md)) |
| Eject reports `unmount FAILED` | a file in the mount is still open | stop playback/browser; the script retries lazily and still releases the device. Full log: `/data/usb-eject.log` ([15](15-nh08s-power-and-eject.md)) |
| Ejected stick remounts immediately | USB watcher restarted before the device disappeared, or `edisksd` is running | the watcher is stopped during eject; stop `edisksd` ([10](10-usb.md)) |
| SD card not seen as USB2 | card inserted while `edisksd` owns it, or its `/sys/block/<dev>/device/type` is not `SD` | `sh /data/usb-watch.sh status` lists detected media and both slots; the internal eMMC (`MMC`) is deliberately ignored ([10](10-usb.md)) |
| Ejected SD card remounts by itself | the card is still in the slot | expected: it stays in `/tmp/usb-held` until pulled and reinserted ([15](15-nh08s-power-and-eject.md)) |
| SHIFT + right VINYL logs `REC NOT READY (no USB2 media)` | slot 2 has no card/stick, or `/tmp/usb-name-2` is missing | insert media and confirm `sh /data/usb-watch.sh status`; the shim gates on `/tmp/usb-name-2` ([10](10-usb.md)) |
| SHIFT + right VINYL logs `prepare timeout` / `start timeout` | target not writable, less than ~32 MB free, or 999 files already used | check `/tmp/knobshim.log`, free space on `PIONEER REC/` and the file count ([08](08-controls.md#master-mix-recording-to-usb2-nh08s)) |
| REC icon invisible but a WAV keeps growing | on-screen status reads the engine, which is recording; the icon may not repaint until the next UI tick | stop with the same gesture and check `/tmp/knobshim.log` for `REC START`/`REC STOP` ([08](08-controls.md#master-mix-recording-to-usb2-nh08s)) |
| `RECTMP.WAV` left after removing a card | recording was cut without the mailbox stop | always eject with SHIFT + SoundSwitch or the power button; `/data/rec-stop.sh` finalises the WAV first ([15](15-nh08s-power-and-eject.md)) |

## Power button

| Symptom | Cause | Fix |
|---|---|---|
| Power button still hard-powers-off without teardown | hook not installed (missing `/data/poweroff-hook.so` or `/data/rbp-shutdown.sh`) or the daemon failed to restart | `systemctl cat az01-power-button.service` must show the `/run` drop-in; check `/data/start-rb.log` and `/data/rbp-shutdown.log` ([15](15-nh08s-power-and-eject.md)) |
| Hook remains active after returning to Engine OS | `stop-rbp-return-engine.sh` was not used | remove `/run/systemd/system/az01-power-button.service.d` and restart the unit ([15](15-nh08s-power-and-eject.md)) |
| No `/data/rbp-shutdown.log` after pressing power | daemon did not call libc `reboot()` or the `.so` failed to load | `systemctl status az01-power-button.service`; check the daemon environment ([15](15-nh08s-power-and-eject.md)) |

## Audio

| Symptom | Cause | Fix |
|---|---|---|
| No sound on the built-in speakers | audioshim opened too few channels | JP21: open 8 ch, monitors on 6/7; NH08: open 6 ch, speakers on 4/5 ([09](09-audio.md)) |
| Main/headphone distortion | S24 samples not sign-extended before gain scaling | sign-extend `(l<<8)>>8` before scaling ([09](09-audio.md)) |
| No headphone cue | cue bus (rbp device 1) not routed | JP21: route to 4/5; NH08: route to 2/3 + drive `MixerEngine::setMixerChHeadphoneCue` ([09](09-audio.md)) |
| Main VU pinned at max / lags channels | wrong S24 full-scale; separate meter source | true S24 peak + rbp's own master meter ([09](09-audio.md)) |
| Phasing when cue mix is centred on the cued track | summing rbp's master + cue streams (separate ALSA devices, not sample-aligned) | route rbp's phone stream with rbp's master cue on ([09](09-audio.md)) |
| No MASTER CUE button on the SC Live 4 | XDJ-RX3 has one; SC Live 4 doesn't | strips 3/4 PFL toggle `setMasterOutHeadphoneCue` ([09](09-audio.md)) |
| Loud ~100 ms noise on the speakers at startup | codec/DSP start transient | all-channel `STARTUP_MUTE_MS` mute + fade ([09](09-audio.md)) |
| `-EBUSY` opening `hw:1,0` | `engine.service` holds the codec | stop it first |
| Knob volume → loud distortion | software gain on the ch 6/7 stream | run fixed `SPEAKER_GAIN=1.0` ([09](09-audio.md)) |
| `set_format(S24_LE)` fails on Mixstream | NH08 may only advertise S32_LE | add an S32_LE fallback and left-shift samples ([09](09-audio.md), [14](14-mixstream-pro-plus-survey.md)) |
| Mixstream speakers silent with 6 ch | ETA5805 amp not configured, or the physical SPEAKER/MASTER knobs or channel faders are down | the panel reports the real positions via the NH08S SysEx; raise the knobs/faders. The UCM (`alsaucm -c NH08 set _verb HiFi`) fails on the ETA5805 control set ([09](09-audio.md)) |
| Track plays but main/speaker output is silent | physical channel fader or MASTER knob is at 0 | the NH08S absolute query now delivers their positions; move the fader/knob ([14](14-mixstream-pro-plus-survey.md)) |
| USB stick mounted at `/media/DMBEST`, rbp sees nothing | `edisksd` owns the whole-disk vfat mount | stop `edisksd`, let `usb-watch.sh` own `/media/usb1/sda1` ([14](14-mixstream-pro-plus-survey.md)) |

## Tooling / build

| Symptom | Cause | Fix |
|---|---|---|
| `cannot find libpthread_nonshared.a` | RX3 rootfs lacks the dev archive | `scripts/shims/Makefile` creates empty stubs in `compat/` |
| `GLIBC_2.17`/`GLIBC_2.34` in a shim | linked against host glibc | link the RX3 libs; verify with `objdump -T … | grep GLIBC` |
| `tar: invalid option -- 'z'` on device | busybox tar | `zcat file.tgz \| tar x -C dir` |
| `amidi: Device or resource busy` | the shim's sequencer subscription holds the raw MIDI | capture via the shim's `KNOB_VERBOSE` log instead |
| Exec bits lost on `/bin/*` | Windows/WSL extraction | `scripts/build-chroot.sh` restores them (or `chmod -R 755`) |

## Diagnostic tools

* `tools/touchdump` (static ARM) — ILI2117 ranges + live events.
* `crashcatch.so` — SIGSEGV only: `pc`/`lr` → `/tmp/crash.log`; its handler
  exits the process, so it also suppresses the kernel core for that signal.
* `/data/start-rb-coredump.sh` — crash-dump launcher: enables the stock
  `az01-coredump` helper, skips `crashcatch.so`, records rbp's exit
  status/signal and dmesg, and lists this run's cores in
  `/data/rbp-diag/<timestamp>/exit-status.txt`. Cores are zstd files under
  `<media>/Engine Library/coredumps/` (or `/data/coredumps` with no media).
  With the USB watcher's bind mounts, `choose-dump-directory` can print
  several mount targets and `az01-coredump` uses only the first line, so the
  core can land at the USB root instead; the launcher now searches both.
* `KNOB_VERBOSE=1` → every MIDI event + keycode in `/tmp/knobshim.log`.
* `cat /tmp/audioshim.log` — negotiated params + `sg`/peaks.
* `cat /tmp/dfbdig*.log` — DirectFB bring-up (`ROTINIT` line).
* `aplay`/`amixer`/`alsactl` for audio probing on the SC Live 4. The
  Mixstream Pro Plus lacks them; use `alsaucm`, or cross-build a small test
  tool. `amidi`/`aplaymidi`/`aseqdump` are present on both.
* No `strace`/`gdb` on device — cross-build and `scp` if needed.
