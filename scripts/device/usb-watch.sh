#!/bin/sh
# =============================================================================
# usb-watch.sh — two-slot USB/SD media watcher for rbp (rekordbox player)
#
# Adapted from PrimeBox.  On the SC Live 4 the media USB-A port(s) enumerate on
# the DWC OTG controller (usb1): a stick plugged in the back appears as
#   /sys/block/sda -> .../platform/ff540000.usb/usb1/1-1/.../block/sda
# usb2 (EHCI) / usb3 (OHCI) are watched too.  On the Mixstream Pro Plus the
# SD slot enumerates as an mmcblk device whose /sys/block/<dev>/device/type is
# "SD" (the internal eMMC reports "MMC" and is never touched).
#
# Slot policy: an SD card prefers slot 2, a USB stick prefers slot 1, and an
# attached device keeps its slot until it is removed or ejected.  Slots:
#
#   slot 1  /dev/sdX1     -> /media/usb1/sda1   /tmp/udev_usb1  (library USB)
#   slot 2  /dev/sdX1|mmcblkXpN -> /media/usb4/sda1  /tmp/udev_usb2  (SD)
#
# On attach: mount, bind into the chroot, publish /tmp/usb-name-N and
# /tmp/usb-kind-N, then notify rbp.  Media with a rekordbox export is retried
# until rbp opens export.pdb; plain media gets one umount/mount pair.
# On detach: stop a recording on slot 2 first, notify rbp, then unmount.
#
# This mirrors the XDJ-RX3 udev rule 12-usb-memory-auto-mount.rules.
# The mount event alone is sufficient — never write to /tmp/udev_usbctn*
# ("connect" there triggers rbp's "USB Error. Remove the device." popup).
#
# Usage:  sh /data/usb-watch.sh start|stop|status|run
# Env:    USBWATCH_BUSES="1 2 3"   (sysfs usbN controllers to watch)
#         USBWATCH_POLL=1          (poll interval seconds)
# =============================================================================

S1_MNT=/media/usb1/sda1
S1_CH=/data/rbx3-run/media/usb1/sda1
S1_FIFO=/tmp/udev_usb1
S2_MNT=/media/usb4/sda1
S2_CH=/data/rbx3-run/media/usb4/sda1
S2_FIFO=/tmp/udev_usb2
REQ=/tmp/usb-eject.req
HELD=/tmp/usb-held
LOG=/data/usbwatch.log
PIDFILE=/tmp/usbwatch.pid
BUSES="${USBWATCH_BUSES:-1 2 3}"
POLL="${USBWATCH_POLL:-1}"
TIMEOUT=/data/timeout

log() { echo "$(date '+%F %T') $$ $*" >> "$LOG"; }

slot_mnt() { [ "$1" = 1 ] && echo "$S1_MNT" || echo "$S2_MNT"; }
slot_ch()  { [ "$1" = 1 ] && echo "$S1_CH"  || echo "$S2_CH"; }
slot_fifo(){ [ "$1" = 1 ] && echo "$S1_FIFO" || echo "$S2_FIFO"; }

# --- media discovery --------------------------------------------------------
# Prints "<dev> <kind>" for each usable whole disk: USB mass storage on a
# watched bus, or an mmcblk device whose type is SD (eMMC is "MMC").
find_media() {
  for blk in /sys/block/mmcblk* /sys/block/sd*; do
    [ -e "$blk" ] || continue
    dev=${blk##*/}
    case "$dev" in
      mmcblk*)
        type=$(cat "$blk/device/type" 2>/dev/null)
        [ "$type" = "SD" ] || continue
        echo "$dev sd"
        continue
        ;;
    esac
    tgt=$(readlink "$blk" 2>/dev/null) || continue
    for b in $BUSES; do
      case "$tgt" in
        *"/usb$b/"*) echo "$dev usb"; break ;;
      esac
    done
  done
}

is_held() {
  [ -f "$HELD" ] || return 1
  grep -qx "$1" "$HELD" 2>/dev/null
}

# Drop hold entries whose block device is gone, so reinsertion works again.
prune_held() {
  [ -f "$HELD" ] || return 0
  tmp="$HELD.$$"
  : > "$tmp"
  while read -r d; do
    [ -n "$d" ] || continue
    [ -e "/sys/block/$d" ] || continue
    echo "$d" >> "$tmp"
  done < "$HELD"
  mv "$tmp" "$HELD"
}

# --- wait for the first partition; fall back to whole-disk filesystem ------
find_partition() {
  dev=$1
  case "$dev" in
    mmcblk*) cand="${dev}p1" ;;
    *)       cand="${dev}1" ;;
  esac
  i=0
  while [ $i -lt 40 ]; do                 # up to 4 s (0.1 s steps)
    [ -b "/dev/$cand" ] && { echo "$cand"; return 0; }
    i=$((i + 1)); sleep 0.1
  done
  if blkid "/dev/$dev" >/dev/null 2>&1; then echo "$dev"; return 0; fi
  return 1
}

# --- tell rbp about a media event (FIFO; rbp keeps it open O_RDWR) ---------
notify() {
  slot=$1
  msg=$2
  fifo=$(slot_fifo "$slot")
  if [ ! -p "$fifo" ]; then
    log "notify: $fifo missing (rbp down?) — skipping"
    return 1
  fi
  if "$TIMEOUT" 3 sh -c 'printf "%s" "$1" > "$2"' sh "$msg" "$fifo" 2>/dev/null; then
    log "notify: slot$slot $msg"
    return 0
  fi
  log "notify: FAILED to write '$msg' to $fifo (rbp down?)"
  return 1
}

# --- send umount+then mount, retrying until rbp opens the DB ---------------
# rbp's DeviceSQL channel takes several seconds to come up after a (re)start;
# a mount event sent before that is silently lost.
notify_mount_until_open() {
  slot=$1
  mnt=$(slot_mnt "$slot")
  if [ -z "$(rbp_pid)" ]; then
    log "attach: slot$slot rbp not running -> defer notification"
    return 1
  fi
  n=0
  while [ $n -lt 12 ]; do
    sleep 4
    notify "$slot" "umount $mnt"
    sleep 0.3
    notify "$slot" "mount $mnt"
    sleep 4
    rbp=$(rbp_pid)
    if [ -n "$rbp" ] && ls -l /proc/$rbp/fd 2>/dev/null | grep -q "export.pdb"; then
      log "attach: slot$slot rbp opened export.pdb (attempt $n)"
      return 0
    fi
    n=$((n + 1))
  done
  log "attach: slot$slot rbp never opened export.pdb after retries"
  return 1
}

# --- mount + chroot bind + notify ------------------------------------------
attach() {
  slot=$1
  dev=$2
  kind=$3
  mnt=$(slot_mnt "$slot")
  chm=$(slot_ch "$slot")
  part=$(find_partition "$dev") || { log "attach: no usable partition on $dev"; return 1; }

  src=""
  if mountpoint -q "$mnt"; then
    src=$(awk -v m="$mnt" '$2 == m { print $1; exit }' /proc/mounts)
  fi
  if [ "$src" = "/dev/$part" ]; then
    log "attach: slot$slot $mnt already mounted from /dev/$part (refreshing bind only)"
  else
    # A pulled device, or a watcher restart, can leave $mnt pointing at a
    # device that is gone (sda1) while the new one enumerated as sdb1.
    if [ -n "$src" ]; then
      log "attach: slot$slot $mnt is stale ($src, want /dev/$part) -> remounting"
      if mountpoint -q "$chm"; then umount -l "$chm" 2>/dev/null; fi
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null
    fi
    fstype=$(blkid -s TYPE -o value "/dev/$part" 2>/dev/null)
    [ -n "$fstype" ] || fstype=vfat
    mkdir -p "$mnt"
    case "$fstype" in
      vfat)    mount -t vfat -o flush,rw,noatime,shortname=mixed,dmask=000,fmask=000,codepage=437,iocharset=iso8859-1,usefree,utf8 "/dev/$part" "$mnt" ;;
      exfat)   mount -t exfat -o rw,noatime "/dev/$part" "$mnt" ;;
      hfsplus) mount -t hfsplus -o force,rw,noatime "/dev/$part" "$mnt" ;;
      *)       mount "/dev/$part" "$mnt" ;;
    esac
    rc=$?
    if [ $rc -ne 0 ]; then
      log "attach: slot$slot mount /dev/$part -> $mnt failed rc=$rc"
      return 1
    fi
    log "attach: slot$slot mounted /dev/$part ($fstype, $kind) -> $mnt"
  fi

  mkdir -p "$chm"
  if ! mountpoint -q "$chm"; then
    if ! mount --bind "$mnt" "$chm"; then
      log "attach: slot$slot chroot bind $mnt -> $chm failed"
      return 1
    fi
    log "attach: slot$slot chroot bind ok ($chm)"
  fi

  # Markers are the shim's only readiness check for recording.
  label=$("$TIMEOUT" 2 blkid -s LABEL -o value "/dev/$part" 2>/dev/null)
  printf '%s\n' "$label" > "/tmp/usb-name-$slot"
  printf '%s\n' "$kind" > "/tmp/usb-kind-$slot"
  log "attach: slot$slot marker label='$label' kind=$kind"

  # The bind must exist BEFORE rbp checks the files (export.pdb etc.).
  if [ -f "$mnt/PIONEER/rekordbox/export.pdb" ]; then
    notify_mount_until_open "$slot"
  else
    # Plain media (SD card): one pair is enough; do not stall the loop.
    notify "$slot" "umount $mnt"
    sleep 0.3
    notify "$slot" "mount $mnt"
  fi
  return 0
}

# --- stop a slot-2 recording, notify rbp, release mounts -------------------
detach() {
  slot=$1
  mnt=$(slot_mnt "$slot")
  chm=$(slot_ch "$slot")

  if [ "$slot" = 2 ] && [ -x /data/rec-stop.sh ]; then
    log "detach: slot2 asking rec-stop.sh to close the recording"
    sh /data/rec-stop.sh >> "$LOG" 2>&1
  fi
  log "detach: slot$slot notifying rbp"
  notify "$slot" "umount $mnt"
  sleep 1
  if mountpoint -q "$chm"; then umount -l "$chm"; log "detach: slot$slot umount -l $chm"; fi
  if mountpoint -q "$mnt"; then umount -l "$mnt"; log "detach: slot$slot umount -l $mnt"; fi
  rmdir "$chm" 2>/dev/null
  rmdir "$mnt" 2>/dev/null
  rm -f "/tmp/usb-name-$slot" "/tmp/usb-kind-$slot"
}

rbp_pid() { ps -e -o pid,args | awk '/\/root\/pdj\/rbp/ && !/sh -c/ && !/strace/ && !/awk/ {print $1; exit}'; }

# rbp restarted: a library stick needs the retry-until-export.pdb-open loop;
# plain media (SD) only needs one umount/mount pair, so never stall the loop.
renotify() {
  slot=$1
  mnt=$(slot_mnt "$slot")
  if [ -f "$mnt/PIONEER/rekordbox/export.pdb" ]; then
    notify_mount_until_open "$slot"
  else
    notify "$slot" "umount $mnt"
    sleep 0.3
    notify "$slot" "mount $mnt"
  fi
}

run() {
  log "=== usb-watch run: watching buses [$BUSES], poll ${POLL}s ==="
  slot_dev1=""
  slot_dev2=""
  slot_kind1=""
  slot_kind2=""
  last_rbp=$(rbp_pid)

  while :; do
    # SHIFT + SoundSwitch in rbp writes this request (rbp is chrooted and
    # cannot exec /data/usb-eject.sh). Hand the watcher role over to the eject
    # script, then exit: the script stops/restarts the watcher around the
    # unmount so this loop cannot remount the media mid-eject.
    if [ -f "$REQ" ]; then
      ts=""; mode=""
      read -r ts mode < "$REQ" 2>/dev/null
      now=$(date +%s)
      rm -f "$REQ"
      case "$ts" in
        ''|*[!0-9]*)
          log "eject: bad request '$ts $mode' -> ignored"
          ts=0
          ;;
      esac
      if [ $((now - ts)) -gt 15 ]; then
        log "eject: stale request (ts=$ts mode=$mode) -> ignored"
      elif [ ! -f /data/usb-eject.sh ]; then
        log "eject: request ($mode) but /data/usb-eject.sh is missing"
      else
        log "eject: request ($mode) -> running /data/usb-eject.sh"
        rm -f "$PIDFILE"
        nohup setsid sh /data/usb-eject.sh >/dev/null 2>&1 &
        exit 0
      fi
    fi

    prune_held

    # Drop slots whose device disappeared, then (re)assign the rest.
    if [ -n "$slot_dev1" ] && [ ! -e "/sys/block/$slot_dev1" ]; then
      log "detach: slot1 device $slot_dev1 disappeared"
      detach 1
      slot_dev1=""; slot_kind1=""
    fi
    if [ -n "$slot_dev2" ] && [ ! -e "/sys/block/$slot_dev2" ]; then
      log "detach: slot2 device $slot_dev2 disappeared"
      detach 2
      slot_dev2=""; slot_kind2=""
    fi

    find_media > /tmp/usbwatch.media.$$
    while read -r dev kind; do
      [ -n "$dev" ] || continue
      if [ "$dev" = "$slot_dev1" ] || [ "$dev" = "$slot_dev2" ]; then
        continue
      fi
      if is_held "$dev"; then
        continue
      fi
      if [ "$kind" = "sd" ]; then
        pref=2; alt=1
      else
        pref=1; alt=2
      fi
      if [ "$pref" = 1 ] && [ -z "$slot_dev1" ]; then
        slot=1
      elif [ "$pref" = 2 ] && [ -z "$slot_dev2" ]; then
        slot=2
      elif [ "$alt" = 1 ] && [ -z "$slot_dev1" ]; then
        slot=1
      elif [ "$alt" = 2 ] && [ -z "$slot_dev2" ]; then
        slot=2
      else
        log "attach: $dev ($kind) has no free slot -> waiting"
        continue
      fi
      log "attach: detected $dev ($kind) on watched port -> slot$slot"
      if attach "$slot" "$dev" "$kind"; then
        if [ "$slot" = 1 ]; then slot_dev1=$dev; slot_kind1=$kind
        else slot_dev2=$dev; slot_kind2=$kind; fi
      fi
    done < /tmp/usbwatch.media.$$
    rm -f /tmp/usbwatch.media.$$

    rbp=$(rbp_pid)
    if [ -n "$rbp" ] && [ "$rbp" != "$last_rbp" ]; then
      log "attach: rbp restarted ($last_rbp -> $rbp), re-notifying mounts"
      [ -n "$slot_dev1" ] && renotify 1
      [ -n "$slot_dev2" ] && renotify 2
    fi

    # No media on the watched buses but something is still mounted: the
    # device was pulled while the watcher was down.
    if [ -z "$slot_dev1" ] && mountpoint -q "$S1_MNT"; then
      log "detach: stale $S1_MNT with no media device"
      detach 1
    fi
    if [ -z "$slot_dev2" ] && mountpoint -q "$S2_MNT"; then
      log "detach: stale $S2_MNT with no media device"
      detach 2
    fi

    last_rbp=$rbp
    sleep "$POLL"
  done
}

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDFILE"))"
    return 0
  fi
  log "=== usb-watch start ==="
  nohup sh "$0" run >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  sleep 1
  echo "started pid $(cat "$PIDFILE")"
}

stop() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    echo "stopped"
  else
    echo "not running"
  fi
}

status() {
  echo "pid: $(cat "$PIDFILE" 2>/dev/null || echo none)"
  echo "media: $(find_media | tr '\n' ' ')"
  echo "slot1 $S1_MNT: mounted $(mountpoint -q "$S1_MNT" && echo yes || echo no), bind $(mountpoint -q "$S1_CH" && echo yes || echo no), label '$(cat /tmp/usb-name-1 2>/dev/null)'"
  echo "slot2 $S2_MNT: mounted $(mountpoint -q "$S2_MNT" && echo yes || echo no), bind $(mountpoint -q "$S2_CH" && echo yes || echo no), label '$(cat /tmp/usb-name-2 2>/dev/null)'"
  held=$( [ -f "$HELD" ] && tr '\n' ' ' < "$HELD" )
  echo "held: $held"
  echo "--- log tail ---"
  tail -15 "$LOG" 2>/dev/null
}

case "$1" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  run)    run ;;
  *) echo "usage: $0 start|stop|status"; exit 1 ;;
esac
