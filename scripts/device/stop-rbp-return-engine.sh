#!/bin/sh
# stop-rbp-return-engine.sh — stop rbp and hand the device back to the stock
# Engine OS (including the Mixstream enginex units).
#
# engine.service is restarted with reset-failed because a previous stop can
# leave it in the "failed" state, where "systemctl start" would be a no-op.

sh /data/stop-rbp
sleep 2

# Remove the rbp power-button hook so the stock daemon powers Engine off with
# its original behaviour (the drop-in lives under /run because /etc is ro).
rm -rf /run/systemd/system/az01-power-button.service.d
systemctl daemon-reload 2>/dev/null
systemctl restart az01-power-button.service 2>/dev/null

systemctl reset-failed engine.service 2>/dev/null
systemctl start engine.service

# engine.service's drop-in pulls engine-guardian and the enginex units in via
# Wants=; start the ones that a manual stop may have left down explicitly.
# Missing units are ignored.
systemctl start edisksd.service \
                 enginex-rb-bridge.service \
                 enginex-stream-sync.service \
                 enginex-sc5000-deemixd.service 2>/dev/null

echo "Engine OS restored (panel may take a few seconds to redraw)"
