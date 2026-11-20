# 09 — Audio (JP21 / NH08 codecs)

`audioshim.so` supports two codec layouts: the SC Live 4 (JP21, 8-channel)
and the Numark Mixstream Pro / Pro Plus (NH08/NH08S, 6 channels: master,
headphones and the built-in speaker amp). The shim defaults to the NH08
layout;
[`start-rb.sh`](../scripts/device/start-rb.sh) selects JP21 or NH08/NH08S from
the device tree product code, and the layout is also overridable with
environment variables (see below).

## NH08 / Mixstream Pro channel map

`hw:1,0` is the NH08 card. The kernel machine driver exposes at most 6
channels: the master codec owns slots 0–3 and the ETA5805 speaker amp owns
slots 4/5. On the Mixstream Pro Plus the amp is an **ETA5805**
(`eta5805@2f` in dmesg); the stock UCM (`/usr/share/alsa/ucm2/NH08/`) exposes
TAS5805M-class controls for it.

| Channels | Output |
|---|---|
| **0/1** | **master out** |
| **2/3** | **headphones** |
| **4/5** | built-in speakers (only when a 5/6-channel PCM is requested) |

When the PCM is opened with 4 channels, `nh08_hw_params()` sets the speaker
DAI's `channels_min` to 0, so the speaker amp is not part of the PCM at all.
With 6 channels the master codec gets TDM mask `0xF` (slots 0–3) and the
speaker amp gets `0x30` (slots 4/5). **The launcher therefore opens 6
channels on NH08/NH08S by default** (`DEF_CHANNELS=6`); measured on the Pro
Plus: `S24_LE, 6 ch, 44100`, period 64, buffer 128, RUNNING.

The ETA5805 has its own volume knob and no hardware on/off switch. A
6-channel PCM feeds it slots 4/5 with the main mix (the speaker path is a
separate amplifier DAI, not a hardware mirror of the main DAC). The stock UCM
(`/usr/share/alsa/ucm2/NH08/`) targets a TAS5805M control set that the
ETA5805 card does not expose, so `alsaucm -c NH08 set _verb HiFi` fails with
`unable to execute cset 'Input Mixer'` on this device. The amp keeps the
configuration the kernel/Engine left at boot; verify audibly. The shim's
software speaker level follows the physical speaker knob (CC17). If the
hardware knob should be the only speaker level control, set
`SPEAKER_GAIN=1.0` to pin the shim's software gain.

### Layout environment variables

| Variable | Default | Meaning |
|---|---|---|
| `AUDIO_DEVICE` | `hw:1,0` | ALSA playback device |
| `AUDIO_CHANNELS` | `6` | 2 = master only, 4 = master + headphones, 6 = add speakers |
| `AUDIO_MASTER_OFFSET` | `0` | first master channel |
| `AUDIO_HP_OFFSET` | `2` | first headphone channel (`-1` = none) |
| `AUDIO_SPEAKER_OFFSET` | `4` | first speaker channel |
| `AUDIO_SPEAKERS` | auto | `0` opens 6 channels but leaves speaker slots silent |

If a bring-up test shows that the master and headphone pairs are reversed,
set `AUDIO_MASTER_OFFSET=2 AUDIO_HP_OFFSET=0`.

Suggested bring-up order:

1. Start with the defaults (6 channels). Check `/tmp/audioshim.log` for
   `channels=6 master=0/1 hp=2/3 speakers=4/5` and
   `format: S24_LE ... channels: 6` in
   `/proc/asound/card1/pcm0p/sub0/hw_params`.
2. Confirm master out on 0/1 and headphones on 2/3. If they are swapped, use
   the offset override above.
3. The speaker path (4/5) follows the physical speaker knob (CC17) and is
   gated only by that knob. Use `SPEAKER_GAIN=1.0` while checking levels.

**Format:** `audioshim.c` requests `SND_PCM_FORMAT_S24_LE`; measured on the
Pro Plus: `S24_LE, 6 ch, 44100`, RUNNING. Engine uses `S32_LE, 6 ch` on the
same card; both are valid. The S32_LE fallback is not required (keep it only
as hardening).

The JP21/SC Live 4 layout is still reachable with
`AUDIO_CHANNELS=8 AUDIO_HP_OFFSET=4 AUDIO_SPEAKER_OFFSET=6`. The shim does not
drive JP21's booth pair at 2/3.

## JP21 channel map (SC Live 4)

XLR main, built-in monitors, headphones (cue + master cue + split cue), booth,
and all panel level knobs/switches are driven by `audioshim.so`.

`aplay -D hw:1,0 -c 8 -f S32_LE`, one pair at a time:

| Channels | Output |
|---|---|
| **0/1** | **XLR/RCA main out** (Main Vol) |
| **2/3** | booth out |
| **4/5** | **headphones** |
| **6/7** | **built-in monitors** (speaker/booth knob + on/off switch) |

The codec exposes **no ALSA mixer controls** (`amixer -c 1 scontrols` is empty)
and the hardware format is **S24_LE** (`hw_params` confirms), so all routing and
level is done in software in `audioshim.so`.

## audioshim routing (JP21)

`scripts/shims/audioshim.c` opens `hw:1,0` with 8 channels (S24_LE, 44.1 kHz):

| rbp stream | ch | gain |
|---|---|---|
| master (device 0) | 0/1 | `g_master_gain` (Main Vol, CC20) |
| master | 6/7 | `g_speaker_gain` (CC15) × `g_speaker_on` (note 41) |
| phones (device 1) | 4/5 | routed **straight through** (rbp mixes it) |
| booth (device 2) | 2/3 | — |

rbp's **phone stream is the headphone bus**. With rbp's **master cue enabled**
it contains cue + master, already mixed and time-aligned by rbp's `HeadPhone`
object (which applies the cue mix, cue level and stereo/split type). The shim
therefore routes ch4/5 directly rather than summing rbp's separate master and
cue ALSA devices (which are not sample-aligned and would comb-filter).

## S24 sign extension

rbp's S24_LE samples are right-justified in 32-bit words but **not
sign-extended** (the top byte is 0), so a sample of −500000 is the int32 word
`0x00F85EE0`. Before any gain is applied the shim sign-extends with
`int32_t sl = (int32_t)(l << 8) >> 8;`, then scales and stores back as S24. The
same helper is used for peak/VU measurement.

## Level / switch controls

| SC Live 4 control | MIDI | Effect |
|---|---|---|
| Main Vol | CC20 ch15 | `g_master_gain`, applied to **ch0/1 only** |
| Speaker/booth | CC15 ch15 | `g_speaker_gain`, applied to **ch6/7 only** |
| Speaker on/off switch | **note 41 ch15** | `g_speaker_on` gates ch6/7 |
| Cue mix | CC18 ch15 | `0x4405` → rbp `HeadPhone` mix rate |
| Cue level | CC19 ch15 | `0x4406` → rbp headphone level |
| Split cue | **note 11 ch15** | `HeadPhone::setStereoType` (0 = split, 1 = stereo) |

Because rbp initialises its mixer *after* the shims load, the VU thread
re-asserts rbp's master level to unity for the first ~30 s (alongside the
fader/EQ absolute-control re-assert).

## Cue / PFL (rbp has no PFL keycode)

rbp's XDJ-RX3 panel only exposes deck CUE (`0x4102`) and MASTER CUE (`0x4407`);
there is **no per-channel PFL keycode**, so the SC Live 4 strips drive rbp's
mixer engine directly:

```
mixerengine::MixerEngine singleton      @0x011493c0
setMixerChHeadphoneCue(EnMixerInput,b)  @0x000575a0
getMixerChHeadphoneCue(EnMixerInput)    @0x000575e8
setMasterOutHeadphoneCue(bool)          @0x0005766c
getMasterOutHeadphoneCue()              @0x0005767c
setHeadphoneStereoType(type)            @0x0005768c
```

* strips **1/2** PFL (ch 0/1, note 13) → toggle that channel's headphone cue;
  the strip's PFL LED mirrors the state.
* strips **3/4** PFL (ch 2/3, note 13) → toggle rbp's **master cue** (the SC
  Live 4 has no MASTER CUE button). Their LEDs mirror it.
* rbp's **master cue is enabled at startup** so the headphone bus contains the
  master out of the box.

## VU meters

Master and channel meters both come from **rbp's own meters**
(`MonoLvMeter::getLedValue` hook, 11 segments → panel's 6), with the Main Vol
applied to the master in dB. Using one source keeps them consistent. See
[08 — Controls](08-controls.md) for the MIDI details.

## Startup transient

A loud ~100 ms burst from the built-in monitors occurs right after the stream
starts (rbp's first buffers contain a full-scale transient). `audioshim.so`
holds every output channel at zero for `STARTUP_MUTE_MS` (default 1500 ms)
after the first write, then fades in over `STARTUP_FADE_MS` (default 300 ms).

```sh
STARTUP_MUTE_MS=1500 STARTUP_FADE_MS=300   # defaults
STARTUP_MUTE_MS=0                          # disable
```

## Notes

* The speaker/booth and master-out gains are linear (`val/127`); a log curve
  would feel more natural.
* rbp's MASTER CUE is forced on at startup (no physical button); the strip 3/4
  PFL buttons toggle it afterwards.
