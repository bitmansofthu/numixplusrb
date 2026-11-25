# 08 — Controls (SC Live 4 MIDI → rbp keycodes)

> This document describes the **SC Live 4 (`JP21`) map** and the
> **Numark Mixstream Pro Plus (`NH08S`) differences**. Both are built into
> `knobshim2.c`; the product is selected from `KNOBSHIM_PRODUCT` (exported by
> `start-rb.sh`) or the device tree. The NH08S uses decks on ch 2/3, jog CC
> 0x37/0x4D and incremental VU. See
> [14 — Mixstream Pro Plus survey](14-mixstream-pro-plus-survey.md) and
> [13 — roadmap](13-mixstream-pro-plus-roadmap.md).

Transport, deck, mixer, jog, pads and DJ / Sound Color FX are mapped from the
SC Live 4's MIDI control surface onto rbp's key space, and rbp's LED and VU
state is mirrored back onto the panel.

## Source of truth

Engine OS defines every hardware control's MIDI identity in QML:

```
/usr/Engine/AssignmentFiles/PresetAssignmentFiles/JP21/JP21_Controller_Assignments.qml
/usr/Engine/AssignmentFiles/PresetAssignmentFiles/JP21/JP21_Controller_Device.qml
```

`JP21` is the SC Live 4 (internal name `SCX-4`). `knobshim2.c` is built from
these files. The SC Live 4 uses **channels 4/5 for the decks** and **15 for the
global/FX group**.

## MIDI layout (all channels 0-based)

| Surface | seq channel |
|---|---|
| Global (transport/FX/mix) | 15 |
| Deck Left / Right | **4 / 5** |
| Mixer strips **1 / 2** | 0 / 1 |

The SC Live 4 has **4 mixer strips**, but rbp is a **2-channel** mixer, so only
strips **1/2** are mapped (→ decks 1/2). Strips 3/4 are used for the
master-cue function instead (see below).

## Mapping table (as built in `scripts/shims/knobshim2.c`)

### Global (ch 15)

| Control | MIDI | rbp keycode |
|---|---|---|
| LOAD deck 1 / 2 | note 1 / 2 | `0x4311` K_LOAD (deck 1 / 2) |
| BACK | note 3 | `0x420d` K_BACK |
| FWD | note 4 | `0x0201` K_SOURCE |
| Browse knob push | note 6 | `0x420c` K_SELECTOR |
| Browse knob turn | CC 5 | `0x420c` rotate |
| MENU | note 13 | `0x0206` K_MENU |
| VIEW | note 14 | `0x0202` K_BROWSE |
| Crossfader | CC 14 | `0x6017` K_XFADER |
| Main Vol | CC 20 | `g_master_gain` — audioshim, **ch0/1 (XLR) only** |
| Speaker/booth level | CC 15 | `g_speaker_gain` — audioshim, **ch6/7 (built-in monitors)** |
| Speaker on/off switch | note 41 | `g_speaker_on` — gates ch6/7 |
| Split cue switch | note 11 | `HeadPhone::setStereoType` (0 = split, 1 = stereo) |
| Cue mix | CC 18 | `0x4405` K_HPMIX → rbp `HeadPhone` mix rate |
| Cue level | CC 19 | `0x4406` K_HPLEVEL → rbp headphone level |
| Sound Color FX: DualFilter / DubEcho / Noise / Wash | notes 21–24 | `0x50a6`/`0x50a2`/`0x50a4`/`0x50a3` (both channels) |

### Deck (ch 4 = left → deck 1, ch 5 = right → deck 2)

| Control | MIDI | rbp keycode |
|---|---|---|
| CENSOR → **loop exit** | note 1 | `0x410e` K_RELOOP (exits a running loop; re-enters a stored one) |
| SYNC | note 8 | `0x4112` K_SYNC (LED mirrored back on note 8) |
| CUE | note 9 | `0x4102` K_CUE |
| PLAY / PAUSE | note 10 | `0x4101` K_PLAY |
| Pad mode CUES/STEMS | note 11 | `0x4113` K_HOTCUE |
| Pad mode LOOPS/AUTO | note 12 | `0x4114` K_ALOOP |
| Pad mode ROLL/SAMPLER | note 13 | `0x4115` K_SLIPLOOP |
| Pads 1–8 | notes 15–22 | `0x4117`–`0x411e` |
| Pitch bend − / + | notes 29 / 30 | `0x4107` TEMPO RANGE / `0x4108` MT |
| Jog touch | note 33 | `0x4306` |
| Jog rotate | CC `0x11` hi + `0x31` lo (14-bit) | `0x4305` |
| Key lock | note 34 | `0x4108` K_MT |
| VINYL | note 35 | `0x4104` |
| SLIP | note 36 | `0x4110` |
| Loop in / out | notes 37 / 38 | `0x410c` / `0x410d` |
| Auto loop push / turn | note 39 / CC 32 | `0x4114` |
| Pitch fader | CC `0x1F` hi + `0x4B` lo (14-bit, invert) | `0x4109` K_TEMPO_SLIDER |

### Deck — NH08S (ch 2 = left → deck 1, ch 3 = right → deck 2)

Read from `NH08S_Controller_Assignments.qml` and implemented in
`build_maps()` when `g_nh08s` is set.

| Control | MIDI | rbp keycode |
|---|---|---|
| LOAD left / right | **note 1 / 2 on ch15** (measured; the QML nests Load in the deck block but the panel sends global ch15) | `0x4311` K_LOAD (deck 1 / 2) |
| SYNC | note 8 | `0x4112` (hold → MASTER; **SHIFT + SYNC → `0x4111` K_MASTER**, toggles the sync master) |
| CUE | note 9 | `0x4102`; **SHIFT + CUE → `0x4215` K_TRREV** (previous track / back to track start), deck-scoped |
| PLAY / PAUSE | note 10 | `0x4101` |
| Pad mode 1 / 2 / 3 / 4 | notes 11 / 12 / 14 / 13 | `0x4113` HOT CUE, `0x4114` LOOPS, `0x4115` ROLL, `0x4116` BEAT JUMP |
| Pads 1–4 | notes 15–18 | `0x4117`–`0x411a`; with SHIFT, pads 5–8 (`0x411b`–`0x411e`) except in HOT CUE mode (see below) |
| Pitch bend − / + | notes 29 / 30 | `0x4107` TEMPO RANGE / `0x4108` MT, **deck-scoped, press only** |
| **SHIFT + pitch bend +** | note 30 + Shift n28 | `0x410b` **DeckQuantize** — toggles that deck's quantize (ch2 = deck 1, ch3 = deck 2, independent) |
| Jog touch | note 33 | `0x4306` |
| Jog rotate | CC **`0x37` hi + `0x4D` lo** | `0x4305`; 1638 hardware counts/rev → **3600 rbp pulses/rev** (see below) |
| Wheel | note 35 | `0x4104` VINYL (Shift: scratch) |
| **SHIFT + Wheel (right deck only)** | note 35 + Shift n28 | start/stop **master-mix recording to USB2** (normally the SD card); the shifted press/release is swallowed, plain VINYL is unchanged (see below) |
| Shift | note 28 | modifier for CUE / SYNC / pitch bend / Wheel / FX select / pads; also gates Settings → SHORTCUT and VIEW → SEARCH. Sends rbp's internal `0x4103` on the deck channel (see pads below) |
| Pitch fader | CC `0x1F` + `0x4B` | `0x4109`; top = faster (**opposite of JP21**, whose QML has `invert: true`) |

There is no key lock, slip, loop-in/out or censor button on the NH08S; those
JP21 mappings are not installed on this product.

#### NH08S performance pads

The panel has only four pads per deck (notes 15–18), while rbp understands
eight (`K_PAD1..8 = 0x4117..0x411e`). The shim reads rbp's *current* pad mode
live and routes each press accordingly:

| rbp pad mode | plain pad 1–4 | SHIFT + pad 1–4 |
|---|---|---|
| HOT CUE | `K_PAD1..4` (recall or set cue) | same `K_PAD1..4` **plus delete** (see below) |
| AUTO LOOP | `K_PAD1..4` | `K_PAD5..8` |
| SLIP LOOP | `K_PAD1..4` | `K_PAD5..8` |
| BEAT JUMP | `K_PAD1..4` | `K_PAD5..8` |

The mode comes from `ui::StatWatcher`, not from a shim-side guess:

```
g_ui = *(0x02685f2c)                 -> StatWatcher = *(g_ui + 0x38)
stat_deck = *(StatWatcher + 0x0c / 0x10)
raw_mode  = *(unsigned char *)(stat_deck + 0x281)
mode      = raw_mode & 3
```

`PlayerInnards::getStat()` writes that byte as the base mode **plus 4** when
one of its extended flags is set (`+0x79` → 4/HOT CUE, `+0x7a` → 5/AUTO LOOP,
`+0x7b` → 6/SLIP LOOP, `+0x7c` → 7/BEAT JUMP, otherwise the plain 0..3), so the
shim masks with `&3` before any pad logic or LED comparison. Reading a stale
extra `StatWatcher + 0x1c` dereference here crashes rbp (`addr=0x3161`);
`StatWatcher + 0x1c` is the MixBeatFx sub-struct, not the watcher.

**HOT CUE delete.** There is no separate delete keycode. `ui::KeyInput::
getShiftKeyCode()` returns `0x4103`, and `IKeyManager::sendKey()` checks
`isPressed(0x4103, ch)` for channels 1/2, appending that deck channel to
`IKeyInput`'s parameter vector (`+0x18`/`+0x20`). `PlayerInnards::pad_HotCue()`
scans that vector and takes `clearHotCue()` when its own channel is present.
So while NH08S SHIFT (note 28) is held, the shim sends `0x4103` press/release
on that deck's channel; plain and shifted pad presses both keep the normal
`K_PAD1..4` keycode. (Encoding `keycode | (1<<16)` does **not** work —
`sendKey()` stores only the low 16 bits at `IKeyInput+0x8`.)

**Pad LEDs.** `ActionPads` / `PadModeSelect` are `LedType.Simple`, so the shim
sends velocity `0x7f` (on) / `0x00` (off). Pad-mode LEDs always follow rbp's
reported mode. HOT CUE pads light from rbp's `LedStat` ids 18–25 (state 2 =
blink, driven as a panel blink); LOOPS and SLIP LOOP light all four pads; BEAT
JUMP lights the normal pads, and with SHIFT held lights all four (the pads
5–8 layer). Pads 5–8 do not exist physically and are explicitly kept dark.

#### NH08S jog scaling

Two different units are involved, and they are handled separately in
`handle_jog()`:

* **Position (`l`)** — rbp's `playengine::JogPulse` converts every jog pulse
  into `SAMPLE_PER_PULSE_ = 12.25` samples at 44.1 kHz, so one revolution must
  deliver **3600 pulses** (3600 × 12.25 = 44100 = one second of audio at
  1 rev/s). The panel's 14-bit CC reports **1638 counts** per revolution, so
  the shim rescales the position delta by `3600 / 1638` before sending it.
  Without that the scratch/seek moved only ~45 % of the wheel's real speed.
  Per-update deltas are clamped to ±6000 pulses, below rbp's 6480
  wrap-detection threshold (`JogPulse::JOG_MAX_COUNT_`).
* **Speed (`f`)** — `Player::setJogSpeed()` clamps to ±8 rev/s and
  `Player::controlPitchbend()` applies
  `(speed − 0.5 rev/s) × 0.08` with a 0.5 rev/s dead zone, i.e. a 1 rev/s
  nudge is only a 4 % bend. The shim multiplies the measured rev/s by 1.5 on
  the NH08S so normal nudges get past the dead zone; the same value also
  selects the jog-search speed category (0.15 / 0.5 / 1.0 / 1.75 / 2.3 rev/s
  thresholds in `PlayerInnards::onKey_Jog`).

Both are overridable without rebuilding: `JOG_PPR` (hardware counts/rev,
default 1638), `JOG_OUT_PPR` (pulses/rev sent to rbp, default 3600; `0` = no
rescaling), `JOG_SPEED_GAIN` (default 1.5), `JOG_SCALE` (extra multiplier on
the counts) and `JOG_IDLE_MS` (default 120, how long after the last movement
a speed-0 key is sent so a bend ends).

`start-rb.sh` does **not** enable `JOG_VERBOSE`/`TEMPO_VERBOSE` any more:
every logged jog sample opens and writes `/tmp/knobshim.log`, which at a few
hundred events per second added latency and made the wheel feel sluggish.
Use `JOG_VERBOSE=1 sh /data/start-rbp-debug.sh` when the raw
`delta= / pulses= / speed=` lines are needed.

### Global and mixer — NH08S differences

| Control | JP21 | NH08S |
|---|---|---|
| Browse push | note 6 | note 6 (same) |
| MENU / Settings | note 13 | **note 7** → `0x0206` K_MENU |
| SHIFT + Settings | — | **note 7 while Shift n28 is held** → `0x0210` K_SHORTCUT |
| VIEW | note 14 | **note 16**; **SHIFT + VIEW** → `0x0205` K_SEARCH |
| BACK / FWD | notes 3 / 4 | BACK = **note 3** (ch15); no FWD button |
| SOURCE | FWD n4 | SoundSwitch **n34** (repurposed) |
| Cue mix / gain | CC 18 / 19 | **CC 9 / 10** |
| Master vol | CC 20 | **CC 15** |
| Speaker vol | CC 15 | **CC 17** |
| Crossfader | CC 14 | CC 14 (same) |
| Mixer strips | ch 0/1 | ch 0/1 (same: trim CC3, HI CC4, MID CC6, LOW CC8, fader CC14, sweep CC11, PFL n13) |
| FX | global ch 15 | **ch 4/5**: paddle n4 = K_BFX; select n0–n3 = Echo / Flanger / Delay / Trans (see below) |
| VU out | ch15 CC32/33 bitmask | **ch15 CC32/33**, incremental `[0,14,27,40,53,66]` (5 LEDs) |

#### NH08S Beat FX

The Mixstream has four direct-select buttons instead of the RX3's 14-position
selector, and **no LEVEL/DEPTH knob**:

| Button | MIDI | RX3 selector position | Effect |
|---|---|---|---|
| 1 | ch4 n0 | 1 | ECHO |
| 2 | ch4 n1 | 6 | FLANGER |
| 3 | ch4 n2 | 0 | DELAY |
| 4 | ch4 n3 | 9 | **TRANS** (button is labelled Phaser) |
| SHIFT + 1 (ECHO) | ch4 n0 | — | `0x4490` K_BEATPREV — Beat FX beat **down** |
| SHIFT + 2 (FLANGER) | ch4 n1 | — | `0x4491` K_BEATNEXT — Beat FX beat **up** |
| SHIFT + 3 (DELAY) | ch4 n2 | — | `0x448c` K_BFXCH = **0** — Beat FX to channel 1 (PLAYER_0) |
| SHIFT + 4 (PHASER) | ch4 n3 | — | `0x448c` K_BFXCH = **1** — Beat FX to channel 2 (PLAYER_1) |
| paddle deck 1 | ch4 n4 | — | momentary `0x448d` K_BFX (channel unchanged) |
| paddle deck 2 | ch5 n4 | — | momentary `0x448d` K_BFX (channel unchanged) |

`0x448b K_BFXTYPE` takes the **selector position**, not the internal effect
type. Verified from rbp's `BeatEffectManager::storeMaxMinValue` jump table,
the `EnBeatEffectType` enum is:

```
type: 1 Reverb   2 Trans    3 Roll     4 Flanger   5 Echo      6 Delay
      7 Spiral   8 Pitch    9 Phaser  10 Filter   11 VinylBrake 12 SlipRoll
     13 PingPong 14 Helix
```

and the panel position table is:

```
pos:  0  1  2  3  4  5  6  7  8  9 10 11 12 13
type: 6  5 13  7 14  1  4  9 10  2  3 12  8 11
name: Delay Echo PingPong Spiral Helix Reverb Flanger Phaser Filter Trans
      Roll SlipRoll Pitch VinylBrake
```

So the four NH08S buttons select Echo (pos 1), Flanger (pos 6), Delay
(pos 0) and Trans (pos 9).

Since there is no depth knob, `knobshim2.c` sends
`0x448f K_DEPTH = 512/1023 (50 %)` at startup and again before every FX
activation. Without that value rbp switches the effect on (the FX name turns
blue on screen) but leaves it fully dry, so the audio does not change.

**Momentary paddles.** The RX3 FX ON button latches, but the Mixstream paddle
is spring-loaded, so `knobshim2.c` makes it momentary. The paddle does **not**
change the Beat FX channel any more (the channel starts on **MASTER** and is
changed only with SHIFT + DELAY / PHASER):

* pressing a paddle seeds `0x448f K_DEPTH = 512/1023 (50 %)`, then (if the
  effect is off) a `K_BFX` press+release tap turns it **on**;
* the matching release tap turns it **off** again.
* `UiGetMixBeatFxOn()` (`rbp` `0x000fe46c`) reads the ON bit out of the UI
  state so the shim knows whether the user had already latched the effect
  (e.g. from the touch screen). If it was already on, the paddle leaves it on
  at release instead of toggling it off.
* the startup thread keeps re-sending `K_BFXCH = 5 (MASTER)` for the first
  ~3 s (rbp's mixer inits after the shim), so the default channel is MASTER.

**Beat FX channel.** SHIFT + DELAY sends `K_BFXCH = 0` (channel 1) and
SHIFT + PHASER sends `K_BFXCH = 1` (channel 2). Either also sets the
"user chose the channel" flag that stops the MASTER re-assert thread.

**Select LEDs.** The four FX select buttons (ch4 notes 0–3) are lit to mirror
rbp's selected effect. The shim reads the selector position from
`ui::StatWatcher` (`g_ui [0x02685f2c] → +0x38 → +0x1c`, byte `+0xa`) and maps
position 0→Delay (n2), 1→Echo (n0), 6→Flanger (n1), 9→Trans (n3). Any other
position, and the null StatWatcher before rbp has initialised, turns all four
LEDs **off**. The byte stores the 14-position selector index, not the internal
`EnBeatEffectType` (measured: selecting positions 0/1/6/9 stored exactly
0/1/6/9).

**SHIFT + ECHO / FLANGER** are the RX3's BEAT `<` / `>` keys: they send
`0x4490` / `0x4491` with `OP_PRESS` and `l = -1 / +1` (rbp's `asEventCode`
only emits these two keycodes on press).

### Mixer (strips 1/2 → decks 1/2)

| Control | MIDI | rbp keycode |
|---|---|---|
| TRIM | CC 3 | `0x5019` |
| HI | CC 4 | `0x501a` |
| MID | CC 6 | `0x501b` |
| LOW | CC 8 | `0x501c` |
| Channel fader | CC 14 | `0x501e` |
| Sweep FX knob | CC 11 | `0x509d` K_COLOR |
| **PFL / cue (strips 1/2)** | note 13 | drives `MixerEngine::setMixerChHeadphoneCue` **directly** (rbp has no PFL keycode); LED mirrored on note 13 |
| **Master cue (strips 3/4)** | note 13 | drives `MixerEngine::setMasterOutHeadphoneCue` (SC Live 4 has no MASTER CUE button); LEDs mirrored |

### DJ FX (global ch 15)

| Control | MIDI | rbp |
|---|---|---|
| FX activate | note 26 | `0x448d` K_BFX (LED = LedStat 48, blinks while active) |
| Wet/dry knob | CC 4 | `0x448f` K_DEPTH |
| **Channel assign** | **note 40**, velocity = position | `0x448c` K_BFXCH |
| **Effect select** | **CC 35**, relative (1 = +1, 127 = −1) | `0x448b` K_BFXTYPE |
| **Time / parameter** | **CC 36**, relative (1 = +1, 127 = −1) | `0x448e` K_TIME |
| **BEAT < / >** | hold **note 25** (TIME-knob push) + turn CC 36 | `0x4490` / `0x4491` |

#### Channel assign

The panel sends the position as the **note-on velocity of note 40**
(`DJFxAssign { turnCC: 40; velocities: [0,1,2,3,127] }` =
`['Channel3','Channel1','Channel2','Channel4','Main']`). rbp's
`djengine::c_str(EnBeatEffectSelectChannel)` gives the target values:

```
0 = PLAYER_0   1 = PLAYER_1   2 = MIC_0   3 = ASSIGN_A
4 = ASSIGN_B   5 = MASTER     6 = AUX
```

So: **Ch1 → 0, Ch2 → 1, Main → 5**. Ch3/Ch4 are inert — rbp has only two
players, so there is nothing to route them to.

#### Effect select

`onEv_BeatEffectType(SW_BFX_TYPE)` is a **14-position switch** whose positions
map to internal effect types:

```
pos:  0  1  2  3  4  5  6  7  8  9 10 11 12 13
type: 6  5 13  7 14  1  4  9 10  2  3 12  8 11
```

rbp's panel encoder is endless, so the shim keeps a cursor over the 14
positions, seeds it from the current effect (`getBeatEffectType()` inverted
through the table above), and sends the position as `K_BFXTYPE`.

#### Time / parameter and BEAT < / >

`onEv_BeatFxTime` → `BeatFxTimeKnob(value, absolute)` is called with
**absolute = false**, so the argument is a **rotation delta**, not a position —
rbp itself steps and clamps it (it adds `value * 13` to the current percent).

`onEv_BeatFxBeat` (the BEAT `<` / `>` buttons) behaves the same way, and the
SC Live 4 has no such buttons — holding the TIME knob's push and turning it
sends them (-1 = halve, +1 = double). SHIFT + TIME works too.

**Op codes matter here.** `ui::Mixer::asEventCode` maps
`0x448e → 0x2014` (any op), but gates the BEAT buttons:

```
0x4490 -> 0x2015   and   0x4491 -> 0x2016   only when (op & 0xf) == 0
```

so they are sent with **OP_PRESS**.

### Beat-loop knob — experimental

The RX3 has no beat-loop knob (its pads trigger loops). The SC Live 4 knob is
wired behind `BEATLOOP=1` because the safe path depends on rbp's pad mode (see
below). rbp exposes the underlying machinery:

```
PlayerInnards::execAutoBeatLoop(short padIndex, bool)        @0x300c64
  pad index -> size code via a per-mode table, then
  DjEngineIF::setAutoBeatLoop(ch, StAutoBeatLoop{numer,denom}, int, bool, bool)
```

Size tables (base `0x4d3850`, codes resolved to beats):

| selector | 8 sizes |
|---|---|
| pad mode 1, `[this+0x7a] == 0` | **4, 2, 1, 1/2, 1/4, 1/8, 1/16, 1/32** |
| pad mode 1, `[this+0x7a] != 0` | 4/3, 1, 2/3, 1/3, 1/5, 1/6, 1/7, 1/9 |
| pad mode 2 (SLIP) | 16, 8, 4, 2, 1, 1/2, 3, 4/3 |

`ui::PlayerInnards` is **not** reachable via `IUiObjManager::getPlayer()` (that
returns `ui::Player`, channel byte 1/2). It is found by scanning writable
mappings for its vptr, which is **`vtable+8`** (`0x4d1960`), then validating
`+0x26` (channel 2/3), `+0x74` (pad mode) and `+0x30` (engine ptr).

The pad keycode (`K_PAD1..8`) is only a beat loop **while rbp is in its
AUTO/LOOPS pad mode**; `execAutoBeatLoop()` called directly from the shim's MIDI
thread does not run the loop. The whole path is therefore gated behind
`BEATLOOP=1`; the reliable workflow is to select rbp's LOOPS pad mode and drive
the pad keycodes from the knob.

### Not mapped

* Beat-loop knob — experimental, `BEATLOOP=1` (above).
* Parameter (23/24), Layer (31), StopTime (CC 37), Thru (note 15) — no
  direct rbp keycode, or needs a distinct param.
* SHIFT (note 28 per deck) is tracked for the BEAT < / > combo and, on NH08S,
  for the pad layer above. Other JP21 shift-actions are not wired.
* JP21 pad-mode LEDs (11–13) and RGB pad colours (the NH08S four-pad layer is
  driven — see "NH08S performance pads").

## LED output (SC Live 4 panel)

Transport LEDs mirror the engine: PLAY / CUE / SYNC / KEY LOCK / VINYL / SLIP,
both decks.

### How the SC Live 4 drives its LEDs

Every front-panel LED is **MIDI**: Engine OS sends `Note On`/`Note Off` to
the *Control Surface* — rawmidi `hw:0,0` (`/dev/snd/midiC0D0`), or seq
`16:0` from the sequencer side. Velocity encodes colour/brightness
(`(r<<4)|(g<<2)|b`, 2 bits per channel; `0x7F` = bright for the simple
transport LEDs, `Note Off` = dark).

```sh
aplaymidi -p 16:0 ledtest.mid      # note8/9/10 ch4 -> SYNC/CUE/PLAY light up
amidi -p hw:0,0 -S "94 0A 3F"      # PLAY deck1 bright
```

Writing LED MIDI does **not** loop back into the Control Surface input path
(verified with `aseqdump -p 16:0`), so it is safe to do from inside `rbp`.

### The bridge (`knobshim2.so`)

rbp computes its LED state into `uif::LedStat` and encodes it for the
XDJ-RX3's EUP/SUB micons, sent to `/dev/subucom_spi1.0` — a dead FIFO in this
port. `led_thread()` therefore polls rbp's own engine state at 20 Hz through the
`playengine::PlayEngine` singleton and mirrors it onto the JP21 notes:

| LED | note (ch 4/5) | source |
|---|---|---|
| SYNC | 8 | **rbp LedStat id 4** (off / solid / blink) |
| CUE | 9 | loaded && !playing |
| PLAY | 10 | `isPlaying` → solid; loaded && !playing → blink; else off |
| KEY LOCK | 34 | `PlayEngine::isMasterTempo(ch)` |
| VINYL | 35 | `PlayEngine::isVinylMode(ch)` |
| SLIP | 36 | `PlayEngine::isSlipModeOn(ch)` |
| LOOP IN | 37 | derived (rbp's loop ids arrive on channel 0) |
| LOOP OUT | 38 | derived (`isLooping`) |
| AUTO LOOP | 39 | `isAutoBeatLoop(ch)` |

Deck 1 = PlayEngine channel 0, deck 2 = channel 1 (mirrors the RX3
`EnPlayerChannel`; the panel MIDI channels are 4/5).

Env:

* `LED_VERBOSE=1` — log every LED change (`led deckN noteM on/off`)
* `LED_DISABLE=1` — do not touch the panel LEDs

Not yet driven on JP21: pad colours (RGB), pad-mode LEDs (11–13), LOAD /
browse LEDs, CUE id, and the loop LEDs. On NH08S the four physical pads and
their mode LEDs are driven from rbp's live state (see "NH08S performance pads").

The bridge opens `/dev/snd/midiC0D0` (rawmidi) exclusively, so while rbp
runs nothing else can open the Control Surface output (`amidi`/`aplaymidi` will
report "Device or resource busy"). Set `LED_DISABLE=1` to release it.

### Global LEDs driven straight from rbp

The LedStat id for the FX group is **`LedDef::ID + 8`**:

| control | panel note (ch 15) | rbp LED id |
|---|---|---|
| Sound Color FX: Dual Filter | 21 | 41 (`CfxFilter` 33+8) |
| Sound Color FX: Dub Echo | 22 | 43 (`CfxDubEcho` 35+8) |
| Sound Color FX: Noise | 23 | 44 (`CfxNoise` 36+8) |
| Sound Color FX: Wash (Sweep) | 24 | 42 (`CfxSweep` 34+8) |
| Beat FX ON/OFF | 26 | **48** (`EffectOnOff` 40+8) |

These use the same `0` off / `1` solid / `2` blink mapping, so the beat-FX
button blinks exactly while rbp does.

### rbp's own LED state — the translation path

rbp keeps all LEDs in one table, so a shim can mirror it directly:

* Every LED write goes through **two** functions:
  `uif::LedStat::setLedState` and `setLedState_Color`.
* `IUiObjManager::getLedManager()` (0x31deb0) is
  `r3 = *(0x026867c0); r3 = *(r3+104)`, and `LedManager::refStatesNoUpdate()`
  (0x33e3ec) is `add r0,r0,#0x30` — so the `LedStat` is at `LedManager+0x30`.
  Read it live with
  `dd if=/proc/<rbp>/mem bs=1 skip=$((ledstat)) count=16 | od -An -tx4`.
* `LedStat`: `+4` u16 = entry count, `+8` = `Led*` array, `+14` u16 = stride.
  Each `Led` entry is `0x2c` bytes: **`+0` u32 id, `+4` u32 channel,
  `+16` u32 State**.

State values: `0` = off, `1` = solid, `2` = blink, `3` = slip-mode dimming
applied to whole groups.

LedStat id → control map (the `uif::LedDef::ID` numbering used by
`PcControlLedData::LedDefID2Text` does not line up):

| rbp LED id | channel | control |
|---|---|---|
| 3 | 1 | VINYL |
| 4 | 1 | SYNC |
| 5 | 1 | MASTER |
| 6 | 1 | KEY LOCK (master tempo) |
| 10 | 1 | REV |
| 11 | 1 | SLIP |
| 34 | 0 | LOOP IN |
| 53 | 0 | CUE |
| 55 | 0 | PLAY |
| 18–25 | 1/2 | pads / performance row |

Discovery switches in `knobshim2.so`: `LED_DUMP=1` (log every
`(id,ch,state)` change), `LED_SWEEP=1` (drive rbp's keycodes and snapshot the
table around each one).

## VU meters

The panel meters are MIDI CCs. The SC Live 4 uses a **bitwise** encoding; the
Mixstream Pro Plus uses **incremental** values — see the NH08S subsection below
for the latter.

On the SC Live 4 the value is a bitmask of the segments lit, from
`ledCCValues: [0, 1, 3, 7, 15, 31, 63]` with
`vuLedCCIndexing: Bitwise` (so `0x3F` = all six).

Each meter on the SC Live 4 is **6 LEDs, bottom → top: 4 white, 1 blue,
1 orange**.

| meter | MIDI |
|---|---|
| Master L / R | **CC 32 / CC 33**, channel **15** |
| Channel 1 / 2 | **CC 10**, channels **0 / 1** |

Thresholds: master `[-45.7, -25.7, -12.2, -7.2, -4.2, -0.2, 20]`, channels
`[-45.8, -25.8, -12.3, -7.3, -4.3, -0.2, 20]`.

**Master** — `audioshim.so` sees the master mix in `snd_pcm_writei()`; it
computes a per-channel peak (S24_LE full scale `0xFFFFFF`) with a ~300 ms
release and publishes it to the shared `g_vu_peak[2]`. `knobshim2.so`'s
`vu_thread` converts peak → true dB → segment bitmask and sends CC 32/33 on
ch15 at 40 Hz. L and R are independent.

**Channels 1/2** — rbp's channel meter is **11 segments**
(`LED_TABLE = (1<<n)-1` for n = 0..11) and is **pre-fader**, while the panel
has 6. `ui::Mixer::MonoLvMeter::getLedValue()` is the single function that
turns a level into the meter bitmask, so `knobshim2.so` patches its prologue
and hooks it (`install_meter_hook()`; the caller LR identifies master / ch1 /
ch2, and the original runs through an RWX trampoline). `vu_thread` then:

1. takes rbp's lit-segment count (0..11 → uint32, *not* a byte),
2. rescales 11 → 6 (`(n*6+5)/11`),
3. applies the **channel-fader taper** so the meter drops with the fader like
   Engine OS,
4. sends `CC 10` on channel 0 (meter 1) and channel 1 (meter 2).

Env: `VU_TEST=1` (sweep 0→6 segments), `VU_DEBUG=1` (log raw hooked bitmasks +
fader positions), `VU_DISABLE=1`.

### NH08S (Mixstream Pro Plus)

The Mixstream has **one stereo main-level meter pair**, not per-channel strips.
From `NH08S_Controller_Assignments.qml`:

```
VUMeter {
    dBThresholds: [-35.0, -25.0, -21.0, -15.0, -3.0, 30.0]
    ledCCValues: [0, 14, 27, 40, 53, 66]
    vuMeterType: VUMeterType.MainOrChannel
    vuLedCCIndexing: VULedCCIndexing.Incremental
    model: [ {channelName: '1', cc: 32}, {channelName: '2', cc: 33} ]
}
```

The block inherits the QML's `GlobalAssignmentConfig { midiChannel: 15 }`, so
both meters are on **channel 15**: **CC 32 = left, CC 33 = right**. The two
strips have **5 LEDs** each, and the six `ledCCValues` are the incremental
steps "0 lit" … "5 lit" — **not** a bitmask. (This also matches the Mixstream
MIDI map published for Algoriddim djay: ch15 CC32/CC33, value 13…66.)

The panel's **VU Meter Mode** setting (Main / Channel) defaults to Main, so
`knobshim2.c` drives the pair from the master output: `audioshim.so`'s
`g_vu_peak[0]/[1]` are published **after** the Main Vol gain, so the meters
follow the master knob and keep real stereo balance (L and R are independent).
The five LEDs light at **-35, -25, -21, -15 and -10 dBFS**. The top step is
lowered from the QML's `-3` because rbp's post-Main-Vol master peaks at about
**-8 dBFS** on loud material at full master (measured with `VU_DEBUG=1`), so
the QML top step could never light. The trailing `30.0` is the above-top
sentinel and has no LED. The lit count is encoded as `14/27/40/53/66`.

There is deliberately **no fallback to rbp's own master meter**: that meter is
mono and *pre*-Main-Vol, so with the master knob at zero it kept lighting the
LEDs from the channel level. The audioshim post-gain peaks are the only source;
silence and master-at-zero therefore show no LEDs. `VU_OFFSET_DB`
(positive = more sensitive, default `0`) shifts the whole scale for
calibration. `VU_RELEASE` sets the per-block decay factor in `audioshim.so`
(default `0.98`, about 70 ms; the old fixed `0.995` was about 300 ms and felt
sluggish).

> Earlier builds sent channel-meter bitmasks on ch0 CC32 / ch1 CC33 (wrong
> channel/encoding), then reused the JP21 six-LED thresholds and rescaled
> 6 → 5. That made the top two LEDs unreachable and the panel lit only three
> of five. `VU_TEST=1` sweeps all five steps on both strips; `VU_DEBUG=1` logs
> the post-Main-Vol peaks, gain and lit count.

### Sound Color FX (NH08S)

The Mixstream has no Sound Color FX select buttons; its **Sweep FX knob** is
CC11 on each mixer strip. rbp defaults the effect to **Filter** and the knob's
centre detent is 50 %, but both the one-shot Filter select and the parameter
value sent from the shim's `init()` land **before rbp's mixer exists** and are
dropped. `vu_thread` therefore re-asserts `K_FILTER` (press/release on mixer
channels 1/2) every 2 s for the first 30 s, and seeds `K_COLOR = 512` (50 %)
until the panel reports CC11, after which the physical knob owns the value.

### Pitch fader polarity (NH08S)

The NH08S `SpeedSlider` has **no** `invert: true`, while the JP21 one does, so
the two panels are wired in opposite directions. `handle_pitch()` normalises
the 14-bit position as before and then negates it for NH08S (top = faster).
`TEMPO_REV=1` still flips it explicitly on either product.

At startup the shim sends Engine OS's **absolute-control query** sysex
(`F0 00 02 0B 7F 12 04 00 00 F7`, from `JP21_Controller_Device.qml`
`queryAbsoluteControls()`) so the panel reports every fader/knob position
immediately. It first waits until rbp's `KeyManager` exists, then re-asserts the
positions every 2 s for the first **30 s** (deliberately short, so it does not
fight the user).

Two implementation notes:

1. rbp finishes initialising its mixer *after* the shim is loaded, so a value
   sent too early is overwritten and the fader reads "down" until moved once.
2. `handle_cc_abs()` only sends on change, so a repeat query returns the *same*
   values and would be dropped — `led_query_absolute()` therefore invalidates
   the CC cache (`abs_map[].last = -1`) before asking.

### Quantize default (NH08S)

The Mixstream has no QUANTIZE button, so rbp's quantize state would otherwise
be whatever the RX3 startup path left behind. `nh08s_quantize_off()` calls
`djengine::DjEngineIF` directly (`isDeckQuantizing`/`setDeckQuantizing`,
`isBeatEffectQuantizeOn`/`setBeatEffectQuantizeOnOff`) and forces **deck 1,
deck 2 and Beat FX quantize OFF**. It runs every 2 s for the first ~30 s,
while rbp's play engine and effect manager finish initialising, and logs the
state it found. `EnPlayerChannel` is 0-based in `djengine`, so deck 1 = 0 and
deck 2 = 1 (the key protocol's send channel is the separate 1-based `sch`).

**SHIFT + pitch bend +** toggles that deck's quantize. rbp's
`onKey_Quantize` (0x410b) is itself a toggle and takes the deck from the send
channel, so the left deck's gesture (ch2 n30) toggles deck 1 and the right
deck's (ch3 n30) toggles deck 2 — the two decks are independent and pressing
the same gesture again switches the deck back off. The deck is marked
user-set, so `nh08s_quantize_off()` skips it for the rest of the startup
window whether it was just switched on or off.

## Key gestures added by the port

### Source selection on the Mixstream (NH08S)

The NH08S map has no SOURCE key. `knobshim2.c` adds:

| Gesture | Sends | Why |
|---|---|---|
| **Browse push** with a mounted stick and no source selected | `0x0201` K_SOURCE | opens rbp's SOURCE menu (no hardware SOURCE button) |
| **Browse push** in the SOURCE menu | `0x0209` K_USB1 | selects USB1 and populates the browser |
| **SoundSwitch** (note 34) | `0x0201` K_SOURCE | reopens the SOURCE menu at any time |
| **SHIFT + SoundSwitch** | `0x8002` K_USBSTOP on USB manager ch 1+2, then a host eject | safe USB stop/eject; see [15](15-nh08s-power-and-eject.md) |

Details and the measured state variables are in [10 — USB](10-usb.md). The
eject gesture and the power-button hook are in
[15 — NH08S power and eject](15-nh08s-power-and-eject.md).

### Master-mix recording to USB2 (NH08S)

**SHIFT + right-deck Wheel (ch3 note 35)** toggles recording of the master mix.
rbp's native REC key is not usable here: it only arms for a USB2 device whose
rekordbox export is attached. Instead `knobshim2.c` drives
`mixerengine::MixerEngine` directly:

```
prepareRecording("/media/usb4/sda1/PIONEER REC", 0)
  -> poll WavWriter +149 (prepare accepted)
  -> startRecording()
  -> poll WavWriter +156 (recording active)
stopRecording() -> writer renames RECTMP.WAV to REC###.WAV
```

The gesture is deck 2 only and swallows just the shifted press/release: plain
VINYL still toggles vinyl mode, SHIFT + left-deck VINYL is untouched, and JP21
is unaffected. The target is whatever `usb-watch.sh` placed in **slot 2**
(`/media/usb4/sda1`, normally the SD card).

Behaviour and limits:

* Files appear as `RECTMP.WAV` while recording and become `REC001.WAV` (next
  free number) on stop. ~32 MB free space is required; numbering stops at
  `REC999.WAV`, and rbp ends a recording at ~3 hours.
* rbp's **status-bar REC icon and REC timer follow the engine state**, so both
  work with this path. Native error popups (`USB FULL`, `NO USB`, `NOT READY`)
  do **not**, because they are emitted by rbp's native REC path; failures are
  logged to `/tmp/knobshim.log` (`REC NOT READY`, `prepare timeout`,
  `start timeout`).
* TRACK MARK stays usable while recording (rbp gates it on the same engine
  status).
* Before any unmount or power teardown the host asks the shim to stop via
  `/tmp/rec-stop.req` → `/tmp/rec-stop.ack` (`/data/rec-stop.sh`), so the WAV
  is finalised instead of being cut mid-write. See
  [15 — NH08S power and eject](15-nh08s-power-and-eject.md).

Controls the SC Live 4 has that the RX3 does not (or vice versa):

| Gesture | Sends | Why |
|---|---|---|
| **Hold SYNC** (≥ 600 ms) | `0x4111` K_MASTER | SC Live 4 has no MASTER button. Fires at the threshold, not on release. Tap = normal SYNC. |
| **CENSOR** | `0x410e` K_RELOOP | reverse/censor is unused here; it makes a useful loop exit |
| **TIME push + turn** | `0x4490` / `0x4491` | RX3's BEAT `<` / `>` buttons, absent on the SC Live 4 |

The SYNC hold sends nothing until the threshold is reached; sending the press
early and suppressing the release would leave rbp with a stuck SYNC press and
trigger its long-press action (**instant double**).

## Build

```sh
# in WSL (soft-float ARM cross-compile, GLIBC_2.4 only)
cd scripts/shims
make knobshim2.so RX3=/path/to/extracted/XDJRX3-rootfs
```

Deploy: `scp knobshim2.so root@sclive4:/data/knobshim2.so`, then restart rbp
(or run `start-rb.sh`).

## Verify

```sh
# on device: KNOB_VERBOSE=1 logs every event + keycode
cat /tmp/knobshim.log
#   knobshim2: ch4 note10 -> 0x4101 press (sch1)   <-- PLAY on deck 1
```
