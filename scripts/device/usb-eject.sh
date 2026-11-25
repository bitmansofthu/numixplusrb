#!/bin/sh
# =============================================================================
# usb-eject.sh — safely stop and eject all removable media (USB sticks + SD).
#
# Triggered by the NH08S SHIFT + SoundSwitch gesture: knobshim2.c sends rbp's
# native UsbStop keycode (0x8002) on the USB manager channels and writes
# /tmp/usb-eject.req; usb-watch.sh consumes that request and runs this script.
# rbp is chrooted and cannot execute /data scripts directly.
#
# This script only does the OS-level work:
#   1. stop usb-watch (so it cannot remount media mid-eject)
#   2. close any active recording (/data/rec-stop.sh)
#   3. notify rbp "umount ..." on both media FIFOs (PathDecider reset)
#   4. sync, unmount every mount backed by a removable device (including both
#      chroot binds), with a lazy fallback
#   5. power off / remove the device via udisksctl or sysfs device/delete;
#      an SD card has no delete node, so unmount + sync is reported as safe
#   6. remember ejected devices in /tmp/usb-held until they disappear, so the
#      restarted watcher does not immediately remount a card that stays in
#      the slot
#   7. restart usb-watch (unless --shutdown)
#
# Usage: sh /data/usb-eject.sh [--shutdown]
# =============================================================================

LOG=/data/usb-eject.log
LKD=/tmp/usb-eject.lock.d
HELD=/tmp/usb-held
TIMEOUT=/data/timeout
SHUTDOWN=0
[ "${1:-}" = "--shutdown" ] && SHUTDOWN=1

log() { echo "$(date '+%F %T') $$ $*" >> "$LOG"; }
klog() { [ -e /tmp/knobshim.log ] && echo "$(date '+%F %T') usb-eject: $*" >> /tmp/knobshim.log 2>/dev/null; }

# --- one eject at a time (PID-checked lock; survives no fd inheritance) ------
if ! mkdir "$LKD" 2>/dev/null; then
  if [ -f "$LKD/pid" ] && kill -0 "$(cat "$LKD/pid")" 2>/dev/null; then
    if [ "$SHUTDOWN" = 0 ]; then
      log "eject already running (pid $(cat "$LKD/pid"))"
      exit 0
    fi
    # Power-off while an eject is in progress: let that instance finish (it
    # removes the devices), then re-check below. Bounded by the hook's alarm.
    log "waiting for running eject (pid $(cat "$LKD/pid"))"
    i=0
    while [ $i -lt 50 ] && kill -0 "$(cat "$LKD/pid")" 2>/dev/null; do
      i=$((i + 1))
      sleep 0.1
    done
  fi
  log "removing stale eject lock"
  rm -rf "$LKD"
  mkdir "$LKD" 2>/dev/null || { log "cannot create eject lock"; exit 1; }
fi
echo $$ > "$LKD/pid"
trap 'rm -rf "$LKD"' EXIT INT TERM HUP

# --- device discovery -------------------------------------------------------
# USB: any /sys/block/sd* whose sysfs path goes through a USB controller. Do
# not require removable=1: USB-SATA bridges (the az01-usbsata-fixer case)
# report 0 but are still external media the user expects to eject.
# SD: /sys/block/mmcblk* with device/type == "SD"; the internal eMMC reports
# "MMC" and is never touched.
#
# Never touch a device that backs / or /data.
is_system_dev() {
  for mp in / /data; do
    src=$(awk -v m="$mp" '$2 == m { print $1; exit }' /proc/mounts)
    case "$src" in
      "/dev/$1"|"/dev/$1"[0-9]*|"/dev/$1"p[0-9]*) return 0 ;;
    esac
  done
  return 1
}

media_devs() {
  for blk in /sys/block/mmcblk* /sys/block/sd*; do
    [ -e "$blk" ] || continue
    dev=${blk##*/}
    is_system_dev "$dev" && continue
    case "$dev" in
      mmcblk*)
        type=$(cat "$blk/device/type" 2>/dev/null)
        [ "$type" = "SD" ] || continue
        echo "$dev"
        continue
        ;;
    esac
    tgt=$(readlink "$blk" 2>/dev/null) || continue
    case "$tgt" in
      *"/usb"*) echo "$dev" ;;
    esac
  done
}

# Mountpoints whose source is /dev/<dev>, /dev/<dev><partition> or
# /dev/mmcblkXpN.
mounted_from() {
  case "$1" in
    mmcblk*) re="^/dev/${1}p[0-9]*\$" ;;
    *)       re="^/dev/${1}[0-9]*\$" ;;
  esac
  awk -v re="$re" '$1 ~ re { print $2 }' /proc/mounts
}

umount_retry() {
  mp=$1
  [ -n "$mp" ] || return 0
  mountpoint -q "$mp" || return 0
  i=0
  while [ $i -lt 5 ]; do
    umount "$mp" 2>/dev/null && { log "unmount: $mp"; return 0; }
    i=$((i + 1))
    sleep 0.3
  done
  umount -l "$mp" 2>/dev/null && { log "unmount(lazy): $mp"; return 0; }
  log "unmount FAILED: $mp"
  return 1
}

log "=== eject start (shutdown=$SHUTDOWN) ==="
klog "start (shutdown=$SHUTDOWN)"

devs=$(media_devs)
if [ -z "$devs" ]; then
  log "no removable media attached"
  klog "no media attached"
  # The watcher handed the role to us and exited, so resume hotplug here.
  if [ "$SHUTDOWN" = 0 ]; then
    sh /data/usb-watch.sh start >/dev/null 2>&1
    log "usb-watch restarted"
  fi
  exit 0
fi
log "devices: $devs"

# Stop the watcher first so its 1 s poll cannot remount media while the
# mounts are being dropped. In the request flow it already exited and removed
# its pidfile, so this is a no-op.
sh /data/usb-watch.sh stop >/dev/null 2>&1

# Close the recording while the filesystem is still mounted and writable.
if [ -x /data/rec-stop.sh ]; then
  log "recording: requesting stop before unmount"
  sh /data/rec-stop.sh >> "$LOG" 2>&1
else
  log "recording: /data/rec-stop.sh missing, cannot stop gracefully"
fi

# rbp already received UsbStop; this also resets its PathDecider state so
# reinserted media is treated as new. rbp holds the FIFOs open, so a normal
# write cannot block; if a FIFO has no reader (shutdown path, or rbp gone),
# skip instead of blocking forever. The static `timeout` helper is used when
# available: opening a FIFO O_WRONLY with no reader blocks in open(2).
notify_fifo() {
  fifo=$1
  msg=$2
  [ -p "$fifo" ] || return 0
  if [ -x "$TIMEOUT" ]; then
    "$TIMEOUT" 3 sh -c 'printf "%s" "$1" > "$2"' sh "$msg" "$fifo" 2>/dev/null \
      && { log "notify: $msg -> $fifo"; return 0; }
  fi
  if ps -e -o pid,args 2>/dev/null | awk '/[r]oot\/pdj\/[r]bp/ { f=1 } END { exit !f }'; then
    printf "%s" "$msg" > "$fifo" 2>/dev/null && log "notify: $msg -> $fifo"
  else
    log "notify: rbp not running, skipped"
  fi
}
notify_fifo /tmp/udev_usb1 "umount /media/usb1/sda1"
notify_fifo /tmp/udev_usb2 "umount /media/usb4/sda1"
sync
sleep 0.5

fail=0
for dev in $devs; do
  umount_retry /data/rbx3-run/media/usb1/sda1 || fail=1
  umount_retry /data/rbx3-run/media/usb4/sda1 || fail=1
  for mp in $(mounted_from "$dev"); do
    umount_retry "$mp" || fail=1
  done
done
sync

for dev in $devs; do
  if [ -n "$(mounted_from "$dev")" ]; then
    log "skip power-off /dev/$dev: still mounted"
    fail=1
    continue
  fi

  is_sd=0
  case "$dev" in mmcblk*) is_sd=1 ;; esac

  removed=0
  if command -v udisksctl >/dev/null 2>&1; then
    if udisksctl power-off -b "/dev/$dev" >/dev/null 2>&1; then
      log "udisksctl power-off /dev/$dev"
      i=0
      while [ -e "/sys/block/$dev" ] && [ $i -lt 30 ]; do
        i=$((i + 1))
        sleep 0.1
      done
      [ -e "/sys/block/$dev" ] || removed=1
    fi
  fi

  [ "$removed" = 1 ] && continue

  if [ -e "/sys/block/$dev/device/delete" ]; then
    if echo 1 > "/sys/block/$dev/device/delete" 2>/dev/null; then
      log "sysfs delete /dev/$dev"
    else
      log "sysfs delete FAILED /dev/$dev"
      fail=1
    fi
    i=0
    while [ -e "/sys/block/$dev" ] && [ $i -lt 30 ]; do
      i=$((i + 1))
      sleep 0.1
    done
    if [ -e "/sys/block/$dev" ]; then
      log "/dev/$dev still present after delete"
      fail=1
    fi
  elif [ "$is_sd" = 1 ]; then
    log "/dev/$dev has no device/delete node (SD slot) - unmounted and synced, safe to remove"
  else
    log "no device/delete node for /dev/$dev"
    fail=1
  fi
done

# Keep the restarted watcher from remounting a card that cannot be removed in
# software. Entries are pruned by the watcher once the block device is gone.
for dev in $devs; do
  if [ -e "/sys/block/$dev" ] && ! grep -qx "$dev" "$HELD" 2>/dev/null; then
    echo "$dev" >> "$HELD"
  fi
done

if [ "$SHUTDOWN" = 0 ]; then
  sh /data/usb-watch.sh start >/dev/null 2>&1
  log "usb-watch restarted"
fi

if [ $fail -eq 0 ]; then
  log "=== eject ok ==="
  klog "ok"
else
  log "=== eject incomplete ==="
  klog "incomplete (see /data/usb-eject.log)"
fi
exit $fail
