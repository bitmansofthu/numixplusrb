#!/usr/bin/env bash
#
# make-dfb-so0.sh — convert the built DirectFB 1.4 stack to the RX3 ABI
#                   (libX-1.4.so.0 / .so.0.0.0) and verify GLIBC versions.
#
# DirectFB 1.4.16 builds libdirectfb, libdirect and libfusion with SONAME
# libX-1.4.so.6, but the XDJ-RX3 rootfs and scripts/build-chroot.sh expect
# libX-1.4.so.0 pointing at libX-1.4.so.0.0.0.  The DirectFB modules also
# need their NEEDED entries rewritten from .so.6 to .so.0.
#
# Usage:
#   work/make-dfb-so0.sh [LIBDIR]
#
# Environment:
#   DFBLIB      DirectFB lib directory (default: <repo>/work/dfb/lib)
#   MAX_GLIBC   highest accepted GLIBC_x.y symbol version (default: 2.13,
#               the glibc shipped in the RX3 rootfs)
#   CHECK_ONLY  1 = verify only, do not modify any file
#
# Examples:
#   work/make-dfb-so0.sh
#   CHECK_ONLY=1 work/make-dfb-so0.sh
#   MAX_GLIBC=2.7 work/make-dfb-so0.sh
#
# Exit status: 0 if the conversion and all checks succeed, 1 otherwise.

set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

LIBDIR="${1:-${DFBLIB:-$REPO/work/dfb/lib}}"
MAX_GLIBC="${MAX_GLIBC:-2.13}"
CHECK_ONLY="${CHECK_ONLY:-0}"
MODULE_DIR="$LIBDIR/directfb-1.4-6"
CORE_LIBS=(directfb direct fusion)

FAIL=0

info() { printf '== %s\n' "$*"; }
ok()   { printf '   OK  %s\n' "$*"; }
warn() { printf '   WARN %s\n' "$*" >&2; }
err()  { printf '   FAIL %s\n' "$*" >&2; FAIL=1; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- sanity ----------------------------------------------------------------

command -v patchelf >/dev/null 2>&1 \
  || die "patchelf not found (sudo apt-get install patchelf)"
command -v readelf  >/dev/null 2>&1 \
  || die "readelf not found (sudo apt-get install binutils)"
[ -d "$LIBDIR" ] || die "DirectFB lib directory not found: $LIBDIR"
case "$CHECK_ONLY" in 0|1) ;; *) die "CHECK_ONLY must be 0 or 1" ;; esac

# --- helpers ---------------------------------------------------------------

# Find the newest real libX-1.4.so.* file, ignoring the .so.0.0.0 we generate.
find_source() {
  local base="$1" src
  src="$(find "$LIBDIR" -maxdepth 1 -type f \
           -name "lib${base}-1.4.so.*" \
           ! -name "lib${base}-1.4.so.0.0.0" \
           -print 2>/dev/null | sort -V | tail -n 1)"
  [ -n "$src" ] || return 1
  printf '%s\n' "$src"
}

soname_of() {
  readelf -dW "$1" 2>/dev/null | awk -F'[][]' '/SONAME/ { print $2; exit }'
}

needed_of() {
  readelf -dW "$1" 2>/dev/null | awk -F'[][]' '/NEEDED/ { print $2 }'
}

# Unique GLIBC_x.y symbol versions referenced by a file.
glibc_versions_of() {
  local data
  data="$(readelf --version-info -W "$1" 2>/dev/null || true)"
  printf '%s\n' "$data" \
    | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
    | sed 's/^GLIBC_//' \
    | sort -uV || true
}

# True if version $1 is strictly greater than version $2.
version_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# --- conversion ------------------------------------------------------------

convert_core() {
  local base="$1" src dst soname
  soname="lib${base}-1.4.so.0"
  dst="$LIBDIR/lib${base}-1.4.so.0.0.0"

  if ! src="$(find_source "$base")"; then
    die "no source library lib${base}-1.4.so.6* found in $LIBDIR"
  fi

  info "converting $(basename "$src") -> $(basename "$dst")"
  cp -a -- "$src" "$dst"

  # One patchelf call: fewer rewrites, fewer appended LOAD segments.
  patchelf \
    --set-soname "$soname" \
    --replace-needed libdirectfb-1.4.so.6 libdirectfb-1.4.so.0 \
    --replace-needed libdirect-1.4.so.6   libdirect-1.4.so.0 \
    --replace-needed libfusion-1.4.so.6   libfusion-1.4.so.0 \
    "$dst"

  ln -sfn "$(basename "$dst")" "$LIBDIR/$soname"
  ln -sfn "$(basename "$dst")" "$LIBDIR/lib${base}.so"
}

fix_module_needed() {
  [ -d "$MODULE_DIR" ] || { warn "module directory missing: $MODULE_DIR"; return; }

  local m count=0
  while IFS= read -r -d '' m; do
    [ -f "$m" ] || continue
    patchelf \
      --replace-needed libdirectfb-1.4.so.6 libdirectfb-1.4.so.0 \
      --replace-needed libdirect-1.4.so.6   libdirect-1.4.so.0 \
      --replace-needed libfusion-1.4.so.6   libfusion-1.4.so.0 \
      "$m"
    count=$((count + 1))
  done < <(find "$MODULE_DIR" -type f -name '*.so' -print0 2>/dev/null)
  info "rewrote NEEDED entries of $count module(s)"
}

# --- verification ----------------------------------------------------------

verify_layout() {
  local base dst soname got link
  info "verifying .so.0 layout"
  for base in "${CORE_LIBS[@]}"; do
    dst="$LIBDIR/lib${base}-1.4.so.0.0.0"
    soname="lib${base}-1.4.so.0"

    if [ ! -f "$dst" ]; then
      err "missing $dst"
      continue
    fi

    got="$(soname_of "$dst")"
    if [ "$got" = "$soname" ]; then
      ok "$(basename "$dst") SONAME=$got"
    else
      err "$(basename "$dst") SONAME is '${got:-<none>}', expected '$soname'"
    fi

    for link in "$LIBDIR/$soname" "$LIBDIR/lib${base}.so"; do
      if [ ! -L "$link" ] || [ ! -e "$link" ]; then
        err "missing or broken symlink: $link"
      fi
    done
  done
}

verify_needed() {
  local f bad found=0
  info "verifying NEEDED entries (must not reference .so.6)"
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    bad="$(needed_of "$f" | grep -E '^lib(directfb|direct|fusion)-1\.4\.so\.6$' || true)"
    if [ -n "$bad" ]; then
      err "$(basename "$f") still needs: $(printf '%s ' $bad)"
    fi
    found=$((found + 1))
  done < <(find "$LIBDIR" -maxdepth 3 -type f \
             \( -name 'libdirectfb-1.4.so.*' \
                -o -name 'libdirect-1.4.so.*' \
                -o -name 'libfusion-1.4.so.*' \
                -o -path "$MODULE_DIR/*/*.so" \) -print0 2>/dev/null)
  [ "$found" -gt 0 ] || err "no DirectFB libraries found under $LIBDIR"
}

verify_softfloat() {
  local f flags found=0
  info "verifying ARM soft-float ABI"
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    readelf -h "$f" >/dev/null 2>&1 || continue
    flags="$(readelf -hW "$f" 2>/dev/null | sed -n 's/^  Flags: *//p')"
    case "$flags" in
      *soft-float*) ;;
      *) err "$(basename "$f") is not soft-float: ${flags:-<no flags>}" ;;
    esac
    found=$((found + 1))
  done < <(find "$LIBDIR" -maxdepth 3 -type f \
             \( -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null)
  [ "$found" -gt 0 ] || err "no shared libraries found under $LIBDIR"
}

verify_glibc() {
  local f vers vmax overall="" over=0 count=0
  info "verifying GLIBC symbol versions (target <= $MAX_GLIBC)"

  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    readelf -h "$f" >/dev/null 2>&1 || continue

    vers="$(glibc_versions_of "$f")"
    [ -n "$vers" ] || {
      warn "$(basename "$f") references no GLIBC_* versions"
      continue
    }
    count=$((count + 1))
    vmax="$(printf '%s\n' "$vers" | sort -V | tail -n 1)"

    if version_gt "$vmax" "$MAX_GLIBC"; then
      err "$(basename "$f") needs GLIBC_$vmax (allowed: $MAX_GLIBC)"
      over=$((over + 1))
    fi
    overall="$overall$vers"$'\n'
  done < <(find "$LIBDIR" -maxdepth 3 -type f \
             \( -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null)

  if [ "$count" -eq 0 ]; then
    err "no shared libraries with GLIBC versions found"
    return
  fi

  info "GLIBC versions referenced by the staged tree"
  printf '%s' "$overall" | sort -uV | sed 's/^/   GLIBC_/'

  if [ "$over" -eq 0 ]; then
    ok "all $count libraries reference only GLIBC_* <= $MAX_GLIBC"
  fi
}

# --- main ------------------------------------------------------------------

main() {
  info "DirectFB staging: $LIBDIR"
  if [ "$CHECK_ONLY" = "1" ]; then
    info "CHECK_ONLY=1: no files will be modified"
  else
    local base
    for base in "${CORE_LIBS[@]}"; do
      convert_core "$base"
    done
    fix_module_needed
  fi

  verify_layout
  verify_needed
  verify_softfloat
  verify_glibc

  echo
  if [ "$FAIL" -ne 0 ]; then
    printf 'RESULT: FAILED — see errors above\n' >&2
    exit 1
  fi
  printf 'RESULT: OK — DirectFB stack is RX3-compatible\n'
}

main "$@"
