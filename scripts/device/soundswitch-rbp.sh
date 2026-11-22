#!/bin/sh
# soundswitch-rbp.sh — one-button rbp start on NH08/NH08S.
#
# Installed as the ExecStart of the stock soundswitch.service via a runtime
# drop-in recreated by the patched enginex boot-activate.sh:
# /run/systemd/system/soundswitch.service.d/50-soundswitch-rbp.conf
# Pressing the physical SoundSwitch button in Engine OS then starts rbp instead
# of SoundSwitch, with no SSH required.
#
# start-rb.sh stays in the foreground while rbp is alive, so the service remains
# active for the whole rbp session and becomes inactive when rbp exits.

LOG=/data/soundswitch-rbp.log

echo "$(date '+%F %T') SoundSwitch -> rbp" >> "$LOG" 2>/dev/null
exec sh /data/start-rb.sh
