#!/bin/sh
# start-rb.sh — launch the XDJ-RX3 rekordbox player inside /data/rbx3-run.
# Supports the Denon SC Live 4 (JP21) and the Numark Mixstream Pro / Pro Plus
# (NH08/NH08S); the audio layout is selected from the device tree model data.

# 1. Stop Engine OS + disk service (releases audio, USB, controls).
#    On the Mixstream Pro Plus also stop the enginex layer: engine-guardian
#    can restart Engine, and the enginex-* units hold audio/MIDI/CPU 3.
#    These units do not exist on the SC Live 4, so the stop is harmless there.
systemctl stop engine.service edisksd.service engine-guardian.service \
               enginex-rb-bridge.service enginex-stream-sync.service \
               enginex-sc5000-deemixd.service 2>/dev/null
sleep 1

# 2. Kill any stale rb processes
# BusyBox `ps w` only lists the current TTY here; `ps -e -o pid,args` lists all.
for p in $(ps -e -o pid,args | awk '$0 ~ /[s]trace|[r]oot\/pdj\/[r]bp|[e]db_streamd|[g]dbserver|[u]sb-watch/ {print $1}'); do
    kill -9 $p 2>/dev/null
done
sleep 1

# 2b. Wake the panel. Engine leaves fb0 blanked (FB_BLANK_POWERDOWN, 4);
#     DirectFB can then fail to set up the surface. Safe now Engine is gone.
if [ -w /sys/class/graphics/fb0/blank ]; then
    echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
fi

# 3. Setup device binds, stubs, and FIFOs
sh /data/fix-dev.sh

# 4. Deploy binary and shims into the chroot
cp /data/rbp-audio /data/rbx3-run/root/pdj/rbp
chmod 755 /data/rbx3-run/root/pdj/rbp

cp /data/knobshim2.so /data/rbx3-run/root/pdj/knobshim.so
cp /data/knobshim2.so /data/rbx3-run/usr/lib/knobshim.so
chmod 755 /data/rbx3-run/usr/lib/knobshim.so /data/rbx3-run/root/pdj/knobshim.so

cp /data/audioshim.so /data/rbx3-run/root/pdj/audioshim.so
cp /data/audioshim.so /data/rbx3-run/usr/lib/audioshim.so
chmod 755 /data/rbx3-run/usr/lib/audioshim.so /data/rbx3-run/root/pdj/audioshim.so

cp /data/fbshim-tsc.so /data/rbx3-run/root/pdj/fbshim.so
cp /data/fbshim-tsc.so /data/rbx3-run/usr/lib/fbshim.so
chmod 755 /data/rbx3-run/usr/lib/fbshim.so /data/rbx3-run/root/pdj/fbshim.so

# DirectFB fbdev rotation module: the chroot already ships the patched one;
# only overlay the standalone /data copy when it was deployed.
if [ -f /data/libdirectfb_fbdev-rot16.so ]; then
  cp /data/libdirectfb_fbdev-rot16.so /data/rbx3-run/usr/lib/directfb-1.4-6/systems/libdirectfb_fbdev.so
  chmod 755 /data/rbx3-run/usr/lib/directfb-1.4-6/systems/libdirectfb_fbdev.so
fi

# 5. Clean stale IPC and logs
rm -f /tmp/guard_LocalDBServer /tmp/req_LocalDBServer /tmp/knobshim.log /tmp/audioshim.log /tmp/dfbdig*.log /tmp/rot_surface.dump
rm -f /data/rbp-p.log

# 6. Start EDB daemon inside chroot
export EDB_BIN=/usr/bin
nohup chroot /data/rbx3-run /lib/ld-linux.so.3 /usr/bin/edb_streamd > /data/edb_d.log 2>&1 &
sleep 1

# 7. Stop USB watcher during startup
sh /data/usb-watch.sh stop 2>/dev/null

# 8. Select the codec layout from the device tree product code/compatible.
#    JP21 (SC Live 4): 8 channels — master 0/1, booth 2/3, headphones 4/5,
#    speakers 6/7.  NH08/NH08S (Mixstream Pro / Pro Plus): 6 channels —
#    master 0/1, headphones 2/3, built-in speakers 4/5 (ETA5805).  The NH08
#    PCM accepts S24_LE at 6 channels; 4 channels leaves the speaker DAI out.
#    Any audio variable already present in the environment wins, which allows
#    a one-off bring-up test without editing this script.
PRODUCT=$(cat /proc/device-tree/inmusic,product-code 2>/dev/null)
COMPAT=$(cat /proc/device-tree/compatible 2>/dev/null)
case "$PRODUCT $COMPAT" in
  *JP21*|*jp21*)
    DEF_CHANNELS=8; DEF_MASTER=0; DEF_HP=4; DEF_SPK=6
    AUDIO_LAYOUT="JP21 (SC Live 4)"
    ;;
  *)
    DEF_CHANNELS=6; DEF_MASTER=0; DEF_HP=2; DEF_SPK=4
    AUDIO_LAYOUT="NH08/NH08S (Mixstream)"
    ;;
esac
AUDIO_CHANNELS=${AUDIO_CHANNELS:-$DEF_CHANNELS}
AUDIO_MASTER_OFFSET=${AUDIO_MASTER_OFFSET:-$DEF_MASTER}
AUDIO_HP_OFFSET=${AUDIO_HP_OFFSET:-$DEF_HP}
AUDIO_SPEAKER_OFFSET=${AUDIO_SPEAKER_OFFSET:-$DEF_SPK}
AUDIO_DEVICE=${AUDIO_DEVICE:-hw:1,0}
AUDIO_ENV="AUDIO_DEVICE=$AUDIO_DEVICE AUDIO_CHANNELS=$AUDIO_CHANNELS AUDIO_MASTER_OFFSET=$AUDIO_MASTER_OFFSET AUDIO_HP_OFFSET=$AUDIO_HP_OFFSET AUDIO_SPEAKER_OFFSET=$AUDIO_SPEAKER_OFFSET"
if [ -n "${AUDIO_SPEAKERS:-}" ]; then
  AUDIO_ENV="$AUDIO_ENV AUDIO_SPEAKERS=$AUDIO_SPEAKERS"
fi
if [ -n "${SPEAKER_GAIN:-}" ]; then
  AUDIO_ENV="$AUDIO_ENV SPEAKER_GAIN=$SPEAKER_GAIN"
fi
echo "audio layout: $AUDIO_LAYOUT, ${AUDIO_CHANNELS}ch on $AUDIO_DEVICE (master $AUDIO_MASTER_OFFSET, hp $AUDIO_HP_OFFSET, speakers $AUDIO_SPEAKER_OFFSET)"

# 9. Start rbp cleanly inside chroot
# Panel rotation: the Mixstream Pro Plus is upside down with `left`, so it
# defaults to `right` here. Override per device with DFB_ROTATE=... if needed.
DFB_ROTATE=${DFB_ROTATE:-right}
nohup chroot /data/rbx3-run env PATH=/bin:/sbin:/usr/bin:/usr/sbin DFB_ROTATE=$DFB_ROTATE KNOBSHIM_PRODUCT="${PRODUCT:-$COMPAT}" STARTUP_MUTE_MS=1500 STARTUP_FADE_MS=300 $AUDIO_ENV LD_PRELOAD=/usr/lib/fbshim.so:/usr/lib/knobshim.so:/usr/lib/audioshim.so /lib/ld-linux.so.3 /root/pdj/rbp -a </dev/null >/data/rbp-p.log 2>&1 &

echo "launched rbp, waiting for initialization..."
RBP=""
for i in $(seq 1 30); do
  RBP=$(ps -e -o pid,args | awk '/[r]oot\/pdj\/[r]bp/ && !/sh -c/ && !/awk/ {print $1; exit}')
  if [ -n "$RBP" ] && ls -l /proc/$RBP/fd 2>/dev/null | grep -q udev_usb1; then
    echo "RBP=$RBP ready (udev_usb1 fd opened)"
    break
  fi
  sleep 0.5
done
[ -n "$RBP" ] || RBP=$(ps -e -o pid,args | awk '/[r]oot\/pdj\/[r]bp/ && !/sh -c/ && !/awk/ {print $1; exit}')
[ -n "$RBP" ] || echo "warning: rbp process not detected"

# 10. Start USB watcher once rbp is ready
sh /data/usb-watch.sh start 2>/dev/null

# 11. Wait while rbp is running (so launcher does not redraw on top of rbp)
if [ -n "$RBP" ]; then
  while kill -0 $RBP 2>/dev/null; do
    sleep 2
  done
fi

# Cleanup on exit
sh /data/usb-watch.sh stop 2>/dev/null
for p in $(ps -e -o pid,args | awk '$0 ~ /[r]oot\/pdj\/[r]bp|[e]db_streamd/ {print $1}'); do
    kill -9 $p 2>/dev/null
done
