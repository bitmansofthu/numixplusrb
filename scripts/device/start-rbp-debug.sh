#!/bin/sh
# start-rbp-debug.sh — launch rbp with verbose diagnostics and a raw MIDI
# capture. Detached, so it survives the SSH session. Re-running it restarts
# rbp (start-rb.sh kills any stale player first).
#
# Environment overrides are passed through, e.g.:
#   DFB_ROTATE=left AUDIO_CHANNELS=6 sh /data/start-rbp-debug.sh
#
# Logs:
#   /data/start-rb.log    launcher output ("RBP=<pid> ready")
#   /data/rbp-p.log       rbp stdout/stderr + touch events (FBSHIM_DEBUG)
#   /tmp/knobshim.log     MIDI/LED/VU mapping (verbose)
#   /tmp/audioshim.log    audio levels/peaks
#   /tmp/seqdump.log      raw MIDI from the control surface (aseqdump)
#   /data/edb_d.log       edb_streamd

LOG=/data/start-rb.log

# The capture must not subscribe twice.
pkill aseqdump 2>/dev/null

nohup setsid env KNOB_VERBOSE=1 FBSHIM_DEBUG=1 sh /data/start-rb.sh >"$LOG" 2>&1 </dev/null &

echo "start-rbp-debug: launching, log: $LOG"

# Wait for the *new* instance: matching a PID from 'ps' races with the stale
# player that start-rb.sh is about to kill. The launcher logs the new one.
RBP=""
for i in $(seq 1 120); do
    RBP=$(sed -n 's/.*RBP=\([0-9][0-9]*\) ready.*/\1/p' "$LOG" 2>/dev/null |
          tail -n 1)
    [ -n "$RBP" ] && break
    sleep 0.5
done

if command -v aseqdump >/dev/null 2>&1; then
    setsid aseqdump -p 16:0 >/tmp/seqdump.log 2>&1 </dev/null &
    echo "raw MIDI capture: /tmp/seqdump.log"
fi

echo "verbose shim log: /tmp/knobshim.log"
echo "audio log:        /tmp/audioshim.log"
[ -n "$RBP" ] && echo "rbp pid:          $RBP"
echo "stop with:        sh /data/stop-rbp"
