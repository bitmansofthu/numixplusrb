#!/bin/sh
# install-soundswitch-hook.sh — reapply the NH08S one-button rbp start hook.
#
# The stock root filesystem is dm-verity read-only, so a persistent /etc drop-in
# is impossible. This script inserts a marker-bounded block into enginex's
# boot-activate.sh, which recreates a runtime soundswitch.service drop-in at
# every boot. The block must run *before* boot-activate.sh's final
# `systemctl restart engine.service`; that restart can kill the activation
# process before it reaches anything appended at EOF. Re-run this after any
# enginex update/reinstall replaces boot-activate.sh. Safe to run repeatedly.

set -eu

BOOT=/data/enginex/bundle/boot-activate.sh
WRAPPER=/data/soundswitch-rbp.sh
DROPIN_DIR=/run/systemd/system/soundswitch.service.d
DROPIN="$DROPIN_DIR/50-soundswitch-rbp.conf"
DISABLE=/data/soundswitch-rbp.disable
MARKER='# >>> nh08s-one-button-rbp >>>'
ENDMARKER='# <<< nh08s-one-button-rbp <<<'
ANCHOR='mkdir -p /run/systemd/system/engine.service.d'

log() { printf '%s\n' "$*"; }
fail() { printf 'install-soundswitch-hook: %s\n' "$*" >&2; exit 1; }

[ -f "$BOOT" ] || fail "missing $BOOT (install/reinstall enginex first)"
[ -x "$WRAPPER" ] || fail "missing executable $WRAPPER"

apply_runtime_dropin() {
    if [ -e "$DISABLE" ]; then
        rm -f "$DROPIN" 2>/dev/null || :
        rmdir "$DROPIN_DIR" 2>/dev/null || :
        log "disabled by $DISABLE"
        return 0
    fi

    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN" <<'EOF'
[Service]
Type=simple
ExecStart=
ExecStart=/bin/sh /data/soundswitch-rbp.sh
ExecStopPost=
PIDFile=
Restart=no
TimeoutStopSec=30
EOF
    systemctl daemon-reload >/dev/null 2>&1 || :
    log "runtime drop-in: $DROPIN"
}

block="$BOOT.nh08s-block.$$"
tmp="$BOOT.nh08s.$$"
cleanup() { rm -f "$block" "$tmp" 2>/dev/null || :; }
trap cleanup EXIT INT TERM HUP

cat > "$block" <<'HELPER_BLOCK'
# >>> nh08s-one-button-rbp >>>
# Recreate the runtime soundswitch.service drop-in on every enginex boot.
# Managed by /data/install-soundswitch-hook.sh; remove this block to undo.
# Root is dm-verity, so /etc/systemd/system/... cannot be used on this firmware.
# Keep this block before boot-activate.sh's final Engine restart.
if [ -e /data/soundswitch-rbp.disable ]; then
    rm -f /run/systemd/system/soundswitch.service.d/50-soundswitch-rbp.conf 2>/dev/null || :
    rmdir /run/systemd/system/soundswitch.service.d 2>/dev/null || :
elif [ -x /data/soundswitch-rbp.sh ] && [ "$(cat "${SC5000_PID1_COMM:-/proc/1/comm}" 2>/dev/null)" = systemd ]; then
    mkdir -p /run/systemd/system/soundswitch.service.d
    cat > /run/systemd/system/soundswitch.service.d/50-soundswitch-rbp.conf <<'EOF'
[Service]
Type=simple
ExecStart=
ExecStart=/bin/sh /data/soundswitch-rbp.sh
ExecStopPost=
PIDFile=
Restart=no
TimeoutStopSec=30
EOF
    systemctl daemon-reload >/dev/null 2>&1 || :
fi
# <<< nh08s-one-button-rbp <<<
HELPER_BLOCK

# Remove any previous copy of the block (including the old EOF placement), then
# insert the canonical copy immediately after the early drop-in setup.
if awk -v start="$MARKER" -v end="$ENDMARKER" -v anchor="$ANCHOR" -v blockfile="$block" '
    $0 == start { skipping = 1; next }
    skipping && $0 == end { skipping = 0; next }
    skipping { next }
    {
        print
        if (!inserted && $0 == anchor) {
            while ((getline line < blockfile) > 0) print line
            close(blockfile)
            inserted = 1
        }
    }
    END { if (!inserted) exit 2 }
' "$BOOT" > "$tmp"; then
    :
else
    fail "anchor line not found in $BOOT"
fi

chmod 755 "$tmp"
before=$(sha256sum "$BOOT" | awk '{print $1}')
after=$(sha256sum "$tmp" | awk '{print $1}')
if [ "$before" = "$after" ]; then
    log "boot hook already correct: $BOOT"
else
    backup="$BOOT.pre-soundswitch-rbp.$(date +%Y%m%d%H%M%S)"
    cp -p "$BOOT" "$backup"
    log "backup: $backup"
    mv "$tmp" "$BOOT"
    log "patched: $BOOT"
fi

apply_runtime_dropin
log "verify with: systemctl cat soundswitch.service"
