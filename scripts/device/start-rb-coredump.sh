#!/bin/sh
# start-rb-coredump.sh — diagnostic variant of start-rb.sh for crash dumps.
#
# Differences from start-rb-crashdiag.sh:
#   * enables the stock az01-coredump helper (/data/coredumps.enabled)
#   * does NOT preload crashcatch.so, whose SIGSEGV handler calls _exit() and
#     would suppress the kernel core
#   * records rbp's exit status (134 = SIGABRT, 137 = SIGKILL, 139 = SIGSEGV,
#     0 = normal) and the tail of dmesg
#   * archives the shim/rbp logs and lists the cores written by this run
#
# The kernel core_pattern is "|/usr/bin/az01-coredump ..."; the helper zstd
# compresses the core and writes it to the first attached media's
# "Engine Library/coredumps/<folder>/" (or /data/coredumps when no media).
# With the usb watcher's bind mounts active, choose-dump-directory can emit
# several mount targets; the helper then uses only its first line and drops
# the core at the USB root.  The core search below covers both locations.
# The power-button hook and USBSTOP_* pass-through are kept.
#
# Manual use (do not wire this into soundswitch.service):
#   nohup setsid sh /data/start-rb-coredump.sh &
# The script writes its own console output to /data/start-rb-console.log, so
# no output redirections or pipes are needed on the command line.
# If the launcher itself is killed with SIGKILL, remove
# /data/coredumps.enabled by hand before returning to Engine OS.

# Capture this launcher's own output without relying on the caller to add
# ">/data/start-rb-console.log 2>&1".  The file is truncated at each start;
# per-run crash diagnostics still go to $RUN_DIR.
exec >/data/start-rb-console.log 2>&1

DIAG_ROOT=/data/rbp-diag
RUN_ID=$(date +%Y%m%d%H%M%S)
RUN_DIR=$DIAG_ROOT/$RUN_ID
PREV_DIR=$DIAG_ROOT/previous
CORE_FLAG=/data/coredumps.enabled
STAMP=$RUN_DIR/start.stamp
mkdir -p "$DIAG_ROOT" "$RUN_DIR" "$PREV_DIR"
: > "$STAMP"
printf 'coredump run %s -> %s\n' "$RUN_ID" "$RUN_DIR" >> /data/start-rb.log

# --- core dumps -------------------------------------------------------------
# ulimit is already unlimited for ssh and for soundswitch.service
# (LimitCORE=infinity), but set it explicitly for safety.
ulimit -c unlimited 2>/dev/null
: > "$CORE_FLAG"
cat /proc/sys/kernel/core_pattern > "$RUN_DIR/core-pattern.txt" 2>/dev/null
echo "core dumps enabled ($CORE_FLAG), pattern: $(cat /proc/sys/kernel/core_pattern 2>/dev/null)"

# --- power-button hook ------------------------------------------------------
# /etc is read-only, so install a runtime drop-in under /run/systemd/system.
# The stock az01-pwrbtn daemon then preloads /data/poweroff-hook.so, whose
# reboot() wrapper runs /data/rbp-shutdown.sh before the real poweroff syscall.
# stop-rbp-return-engine.sh removes the drop-in when handing back to Engine OS.
install_power_hook() {
    if ! systemctl cat az01-power-button.service >/dev/null 2>&1; then
        echo "power hook: az01-power-button.service not present; skipped"
        return 0
    fi
    if [ ! -f /data/poweroff-hook.so ] || [ ! -f /data/rbp-shutdown.sh ]; then
        echo "power hook: /data/poweroff-hook.so or /data/rbp-shutdown.sh missing"
        return 0
    fi
    d=/run/systemd/system/az01-power-button.service.d
    mkdir -p "$d"
    cat > "$d/override.conf" <<'EOF'
[Service]
Environment=LD_PRELOAD=/data/poweroff-hook.so
EOF
    systemctl daemon-reload 2>/dev/null
    systemctl restart az01-power-button.service 2>/dev/null
    if ! systemctl is-active --quiet az01-power-button.service 2>/dev/null; then
        echo "power hook: daemon failed to start; removing the drop-in"
        rm -rf "$d"
        systemctl daemon-reload 2>/dev/null
        systemctl restart az01-power-button.service 2>/dev/null
        return 0
    fi
    echo "power hook: installed (LD_PRELOAD=/data/poweroff-hook.so)"
}

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

# 3b. Preload the power-button hook for this rbp session.
install_power_hook

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

# 5. Clean stale IPC and logs, preserving the previous run's diagnostics.
for f in /tmp/crash.log /tmp/knobshim.log /tmp/audioshim.log /data/rbp-p.log /data/usbwatch.log; do
    [ -s "$f" ] && cp -p "$f" "$PREV_DIR/$(basename "$f").$RUN_ID" 2>/dev/null || :
done
rm -f /tmp/guard_LocalDBServer /tmp/req_LocalDBServer /tmp/knobshim.log /tmp/audioshim.log /tmp/dfbdig*.log /tmp/rot_surface.dump
rm -f /tmp/crash.log /data/rbp-p.log

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

# SHIFT + SoundSwitch USB stop: pass the runtime mode through to the shim.
# Default is the RX3-like parallel burst; set USBSTOP_SEQUENTIAL=1 to fall back.
USBSTOP_ENV=""
[ -n "${USBSTOP_SEQUENTIAL:-}" ] && USBSTOP_ENV="$USBSTOP_ENV USBSTOP_SEQUENTIAL=$USBSTOP_SEQUENTIAL"
[ -n "${USBSTOP_GAP_MS:-}" ] && USBSTOP_ENV="$USBSTOP_ENV USBSTOP_GAP_MS=$USBSTOP_GAP_MS"

# 9. Start rbp cleanly inside chroot.
#    No crashcatch.so here: it would catch SIGSEGV and _exit(1), preventing the
#    kernel from writing a core.
# Panel rotation: the Mixstream Pro Plus is upside down with `left`, so it
# defaults to `right` here. Override per device with DFB_ROTATE=... if needed.
DFB_ROTATE=${DFB_ROTATE:-right}
nohup chroot /data/rbx3-run env PATH=/bin:/sbin:/usr/bin:/usr/sbin KNOB_VERBOSE=${KNOB_VERBOSE:-1} DFB_ROTATE=$DFB_ROTATE KNOBSHIM_PRODUCT="${PRODUCT:-$COMPAT}" STARTUP_MUTE_MS=1500 STARTUP_FADE_MS=300 $AUDIO_ENV $USBSTOP_ENV LD_PRELOAD=/usr/lib/fbshim.so:/usr/lib/knobshim.so:/usr/lib/audioshim.so /lib/ld-linux.so.3 /root/pdj/rbp -a </dev/null >/data/rbp-p.log 2>&1 &

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
printf '%s\n' "$RBP" > "$RUN_DIR/rbp.pid"

# 10. Start USB watcher once rbp is ready
sh /data/usb-watch.sh start 2>/dev/null

# 11. Wait for rbp and keep its real exit status (128+signal when it crashed).
RBP_STATUS=""
if [ -n "$RBP" ]; then
  wait "$RBP"
  RBP_STATUS=$?
fi

# 12. Cleanup, then archive diagnostics before the next start overwrites them.
CORES=$RUN_DIR/cores.txt
: > "$CORES"
for d in "/media/usb1/sda1/Engine Library/coredumps" \
         "/media/usb4/sda1/Engine Library/coredumps" \
         /media/usb1/sda1 /media/usb4/sda1 \
         /data/coredumps; do
    [ -d "$d" ] || continue
    find "$d" -type f -newer "$STAMP" \
         \( -name '*.core' -o -name '*.core.zst' -o -name '*.metadata' \
            -o -name '*.log.zst' \) 2>/dev/null >> "$CORES"
done
dmesg > "$RUN_DIR/dmesg.txt" 2>/dev/null
{
    printf 'rbp pid: %s\n' "${RBP:-unknown}"
    printf 'exit status: %s\n' "${RBP_STATUS:-unknown}"
    case "${RBP_STATUS:-}" in
        0)   printf 'signal: none (normal exit)\n' ;;
        129) printf 'signal: 1 (SIGHUP)\n' ;;
        130) printf 'signal: 2 (SIGINT)\n' ;;
        132) printf 'signal: 4 (SIGILL)\n' ;;
        134) printf 'signal: 6 (SIGABRT)\n' ;;
        135) printf 'signal: 7 (SIGBUS)\n' ;;
        136) printf 'signal: 8 (SIGFPE)\n' ;;
        137) printf 'signal: 9 (SIGKILL)\n' ;;
        139) printf 'signal: 11 (SIGSEGV)\n' ;;
        143) printf 'signal: 15 (SIGTERM)\n' ;;
        *)   printf 'signal: unknown\n' ;;
    esac
    printf 'core files written by this run:\n'
    if [ -s "$CORES" ]; then
        sed 's/^/  /' "$CORES"
    else
        printf '  none found\n'
    fi
    printf 'searched: /media/usb1/sda1/Engine Library/coredumps\n'
    printf '          /media/usb4/sda1/Engine Library/coredumps\n'
    printf '          /media/usb1/sda1 (root, bind-mount fallback)\n'
    printf '          /media/usb4/sda1 (root, bind-mount fallback)\n'
    printf '          /data/coredumps\n'
} > "$RUN_DIR/exit-status.txt" 2>/dev/null
cat "$RUN_DIR/exit-status.txt" 2>/dev/null

for f in /tmp/crash.log /tmp/knobshim.log /tmp/audioshim.log /data/rbp-p.log /data/usbwatch.log /data/edb_d.log; do
    [ -s "$f" ] && cp -p "$f" "$RUN_DIR/$(basename "$f")" 2>/dev/null || :
done
printf 'coredump diagnostics: %s\n' "$RUN_DIR" >> /data/start-rb.log

sh /data/usb-watch.sh stop 2>/dev/null
for p in $(ps -e -o pid,args | awk '$0 ~ /[r]oot\/pdj\/[r]bp|[e]db_streamd/ {print $1}'); do
    kill -9 $p 2>/dev/null
done
rm -f "$CORE_FLAG"
echo "core dumps disabled again ($CORE_FLAG removed)"
