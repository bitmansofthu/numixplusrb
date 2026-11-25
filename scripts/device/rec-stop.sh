#!/bin/sh
# =============================================================================
# rec-stop.sh — close rbp's master-mix recording before media is unmounted.
#
# The knobshim2 recorder runs inside rbp (chrooted) and watches a mailbox on
# the shared /tmp.  This host-side helper asks it to call MixerEngine's
# stopRecording() and waits for the writer thread to finish (the WAV is
# renamed from RECTMP.WAV to REC###.WAV on stop).
#
# Called by usb-watch.sh (slot-2 detach), usb-eject.sh (before the first
# unmount) and stop-rbp (before SIGKILL, covering the power-button path).
#
# Usage: sh /data/rec-stop.sh
# Exit:  0 = recording closed (or no rbp), 1 = ack timeout
# =============================================================================

LOG=/data/rec-stop.log
REQ=/tmp/rec-stop.req
ACK=/tmp/rec-stop.ack
LKD=/tmp/rec-stop.lock.d
TIMEOUT=/data/timeout

log() { echo "$(date '+%F %T') $$ $*" >> "$LOG"; }

rbp_running() {
  ps -e -o pid,args 2>/dev/null | awk '/\/root\/pdj\/rbp/ && !/sh -c/ && !/strace/ && !/awk/ { f=1 } END { exit !f }'
}

if ! rbp_running; then
  log "no rbp process -> nothing to stop"
  exit 0
fi

# --- serialise overlapping calls (eject + power-off + watchdog) -------------
if ! mkdir "$LKD" 2>/dev/null; then
  if [ -f "$LKD/pid" ] && kill -0 "$(cat "$LKD/pid")" 2>/dev/null; then
    log "another rec-stop is running (pid $(cat "$LKD/pid")), waiting"
    i=0
    while [ $i -lt 40 ] && [ -d "$LKD" ]; do
      i=$((i + 1))
      sleep 0.1
    done
    exit 0
  fi
  log "removing stale rec-stop lock"
  rm -rf "$LKD"
  mkdir "$LKD" 2>/dev/null || { log "cannot create lock"; exit 1; }
fi
echo $$ > "$LKD/pid"
trap 'rm -rf "$LKD"' EXIT INT TERM HUP

rm -f "$ACK"
now=$(date +%s)
if [ -x "$TIMEOUT" ]; then
  "$TIMEOUT" 2 sh -c 'printf "%s\n" "$1" > "$2"' sh "$now" "$REQ" 2>/dev/null \
    || { log "cannot write $REQ"; exit 1; }
else
  printf '%s\n' "$now" > "$REQ" 2>/dev/null \
    || { log "cannot write $REQ"; exit 1; }
fi
log "requested recording stop ($now)"

# Up to 5 s: a start that was already queued must appear first, then stop.
i=0
while [ $i -lt 50 ]; do
  if [ -f "$ACK" ]; then
    log "recording stop ack: $(cat "$ACK" 2>/dev/null)"
    exit 0
  fi
  i=$((i + 1))
  sleep 0.1
done

rm -f "$REQ"
log "timeout waiting for recorder ack"
exit 1
