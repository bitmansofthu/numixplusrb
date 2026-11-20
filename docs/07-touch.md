# 07 — Touchscreen

The SC Live 4's ILI2117 reports the same 2048×2048 raw range as the Prime GO,
so the `fbshim-tsc.so` transform is reused; the identity touch calibration
files below are what make rbp accept the taps.

**Rotation dependency:** the transform follows `DFB_ROTATE`. For `right`
(DirectFB rot=270, used on the Mixstream Pro Plus) the logical coordinates
are mirrored in both axes (`lx = 1279-lx`, `ly = 799-ly`) because that panel
is 180° from the SC Live 4 mounting. The old `left` mapping is unchanged.
If taps are mirrored on a new panel, set `DFB_ROTATE` correctly first; the
shim derives the flip from it.

## Stack

`rbp` expects a tsc2007 resistive panel at `/dev/tsc2007_2-0048`.
`fbshim-tsc.so` intercepts `open("/dev/tsc2007_2-0048")` and serves a pipe that
a reader thread fills from the ILI2117 evdev with the 6-byte RX3 protocol,
including the rotation transform and debounce burst.

**Event node discovery:** the ILI2117's `eventN` number is *not stable across
boots* — the i2c touch controller and the platform `gpio-keys` driver probe in
varying order, so `event0` is often `gpio-keys` (seen on the Mixstream Pro
Plus: `event0 = gpio-keys`, `event1 = ILI2117 Touchscreen`). The shim therefore
resolves the device at runtime:

1. `FBSHIM_TOUCH_EVDEV=/dev/input/eventN` if set;
2. `/dev/input/by-path/platform-ff160000.i2c-event` (stable i2c-4 link);
3. sysfs scan of `/sys/class/input/event*/device/name` for `ILI2117`/`Touch`;
4. `/dev/input/event0` as a last resort.

Set `FBSHIM_DEBUG=1` to make the shim log the chosen node and each tap
(`fbshim: touch down x,y`) to rbp's stderr (`/data/rbp-p.log`).

## Verified on the SC Live 4

* ILI2117 on `/dev/input/event0`, raw axes `[0, 2048)`.
* Live events confirmed with `tools/touchdump` (static ARM):
  ```
  axis ABS_MT_POSITION_X min=0 max=2048
  axis ABS_MT_POSITION_Y min=0 max=2048
  ... type=3 code=53 (X) value=970, code=54 (Y) value=1608 ...
  ```

## Verified on the Mixstream Pro Plus

* ILI2117 reports `ILI2117 Touchscreen` and appears as **event1** on one boot
  while `gpio-keys` takes event0; the by-path link is
  `platform-ff160000.i2c-event`. The runtime resolver (above) is required —
  hard-coding event0 makes touch dead on boots where gpio-keys wins.
* The shim resolves to `/dev/input/by-path/platform-ff160000.i2c-event`
  (kernel fd shows `event1`); tap coordinates are emitted as
  `fbshim: touch down ...` with `FBSHIM_DEBUG=1`.
* Physical alignment with `DFB_ROTATE=right` still needs a tap test.

## Required files

`rbp` reads `root/settings/TouchCalib_User.dat` (fallback
`TouchCalib_Factory.dat`). The shim's transform assumes an **identity**
calibration, so both files must contain:

```
0
0
320
200
1280
800
```

Line order is load-bearing (offX, offY, scaleX, scaleY, checkX=1280,
checkY=800). `scripts/build-chroot.sh` installs them.

## Notes

* The browse-caution gate patches (`0x2dc228`/`0x2dc46c`) are in `rbp-audio`;
  `knobshim2` additionally clears the caution id at `0x05a191fc` while USB1 is
  mounted.
* Verify raw events with `tools/touchdump /dev/input/event0`.
