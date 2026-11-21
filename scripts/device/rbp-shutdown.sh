#!/bin/sh
# =============================================================================
# rbp-shutdown.sh — graceful rbp teardown for the stock power-button daemon.
#
# /data/poweroff-hook.so is LD_PRELOADed into /usr/bin/az01-pwrbtn (via a
# runtime systemd drop-in installed by start-rb.sh). When the daemon calls
# libc reboot(), the hook runs this script and then performs the real poweroff
# syscall. This script therefore MUST NOT call poweroff/reboot itself.
#
# It stops rbp/edb_streamd/the USB watcher, ejects USB media, releases the
# chroot bind mounts and syncs. Engine OS is intentionally not restarted.
# =============================================================================

LOG=/data/rbp-shutdown.log
LKD=/tmp/rbp-shutdown.lock.d

log() { echo "$(date '+%F %T') $$ $*" >> "$LOG"; }

# Serialise repeated power-button presses: if a cleanup is already running,
# wait for it to finish rather than starting a second one concurrently.
if ! mkdir "$LKD" 2>/dev/null; then
  if [ -f "$LKD/pid" ] && kill -0 "$(cat "$LKD/pid")" 2>/dev/null; then
    log "shutdown already running (pid $(cat "$LKD/pid")) -> waiting"
    i=0
    while [ $i -lt 200 ] && kill -0 "$(cat "$LKD/pid")" 2>/dev/null; do
      i=$((i + 1))
      sleep 0.1
    done
  fi
  rm -rf "$LKD"
  mkdir "$LKD" 2>/dev/null || { log "cannot create shutdown lock"; exit 1; }
fi
echo $$ > "$LKD/pid"
trap 'rm -rf "$LKD"' EXIT INT TERM HUP

log "=== shutdown requested ==="

if [ -f /data/stop-rbp ]; then
  log "stopping rbp"
  sh /data/stop-rbp >> "$LOG" 2>&1
else
  log "warning: /data/stop-rbp missing"
fi

if [ -f /data/usb-eject.sh ]; then
  log "ejecting USB media (shutdown mode)"
  sh /data/usb-eject.sh --shutdown >> "$LOG" 2>&1
fi

# If an eject that was already running when the power button was pressed
# restarted the watcher, stop it again before releasing the binds.
sh /data/usb-watch.sh stop >/dev/null 2>&1

# Release the chroot binds so the next boot starts from a clean tree. The
# media bind is handled by usb-eject.sh, but include it here for the case where
# no USB device was present when the power button was pressed.
for m in media/usb1/sda1 dev proc sys tmp; do
  mp="/data/rbx3-run/$m"
  if mountpoint -q "$mp"; then
    log "unmount $mp"
    umount "$mp" 2>/dev/null
    mountpoint -q "$mp" && umount -l "$mp" 2>/dev/null
  fi
done

sync
log "=== shutdown cleanup done (daemon will power off) ==="
