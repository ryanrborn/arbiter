#!/usr/bin/env bash
# Refuse to ship an OTP release with a binary that dynamically links a shared
# library that is not guaranteed to exist on every supported host.
#
# Why this exists (bd-c6h5dr / #1977): v0.1.69 could not boot on Fedora 44.
# Its bundled ERTS came from the rabbitmq el8 RPM, whose `crypto` NIF is
# linked against the build image's `libcrypto.so.1.1`; OpenSSL-3-only hosts
# (Fedora >= 36, Ubuntu >= 22.04, Debian >= 12, RHEL 9) have no such file, so
# `kernel` died in `on_load` before any Arbiter code ran. The glibc guard
# (scripts/check-release-glibc.sh) passed: the NIF's glibc symbol versions
# were fine — the library it asked for simply was not there.
#
# This guard reads every shipped ELF file's `DT_NEEDED` entries and fails the
# build, naming the file and the library, when one is not on the allowlist
# below. The release bundles its own ERTS, so beyond these it must not rely on
# anything the host may or may not have installed.
#
# Needs `readelf` (binutils): present wherever a C compiler is, which includes
# the release container, CI runners and any host that builds releases.
set -euo pipefail

# Libraries every supported host has: the glibc family (the glibc baseline
# itself is enforced separately by check-release-glibc.sh), the GCC runtime
# (the BEAM JIT and Rust NIFs link it) and ncurses' terminfo (erts line
# editing). Each is part of the minimal base install of RHEL 8/9, Fedora,
# Debian and Ubuntu. Adding to this list is a portability decision — prefer
# linking the dependency statically, as the OTP build does for OpenSSL
# (scripts/build-release-otp.sh).
DEFAULT_ALLOWLIST=(
  ld-linux-x86-64.so.2
  libc.so.6
  libm.so.6
  libdl.so.2
  libpthread.so.0
  librt.so.1
  libutil.so.1
  libgcc_s.so.1
  libstdc++.so.6
  libtinfo.so.6
)

usage() {
  cat <<'USAGE'
Usage: scripts/check-release-shared-libs.sh [--allow LIB]... [--host] <path>...

  <path>       An assembled release directory (e.g. _build/prod/rel/arbiter),
               an OTP install root, or a release tarball (.tar.gz / .tgz /
               .tar). May be repeated.

  --allow LIB  Also accept a dependency on LIB (an exact soname, e.g.
               libz.so.1). May be repeated.

  --host       Also accept any library this machine's dynamic loader can
               resolve (`ldconfig -p`). Only for a release that will run on
               the host that built it (scripts/build-local-release.sh, which
               bundles the host's own OTP) — never for a published artifact.

Scans every ELF file under each path and checks each `NEEDED` shared library
against an allowlist of libraries present on every supported host: the glibc
family, libgcc_s, libstdc++ and libtinfo. Anything else — libcrypto in
particular — must be linked statically or not at all.

Exit status:
  0  every NEEDED library is on the allowlist
  1  at least one is not (each file and library is named), a file could not
     be read, the scan found nothing to check, or the arguments were wrong

Examples:
  scripts/check-release-shared-libs.sh _build/prod/rel/arbiter
  scripts/check-release-shared-libs.sh arbiter-v0.1.70-linux.tar.gz
USAGE
}

ALLOWLIST=("${DEFAULT_ALLOWLIST[@]}")
PATHS=()
HOST_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --allow)
      if [ -z "${2:-}" ]; then
        echo "error: --allow needs a library soname (e.g. --allow libz.so.1)" >&2
        exit 1
      fi
      ALLOWLIST+=("$2")
      shift 2
      ;;
    --host)
      HOST_MODE=1
      shift
      ;;
    --allow=*)
      ALLOWLIST+=("${1#--allow=}")
      shift
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

if [ ${#PATHS[@]} -eq 0 ]; then
  usage >&2
  exit 1
fi

READELF="${READELF:-readelf}"
if ! command -v "$READELF" >/dev/null 2>&1; then
  echo "error: '$READELF' not found — install binutils to run this check." >&2
  exit 1
fi

# Sonames in this host's loader cache, one per line (only with --host).
HOST_LIBS=""
if [ "$HOST_MODE" -eq 1 ]; then
  LDCONFIG=$(command -v ldconfig || echo /sbin/ldconfig)
  if ! HOST_LIBS=$("$LDCONFIG" -p 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]]*\) (.*/\1/p'); then
    echo "error: --host needs ldconfig to list this host's shared libraries." >&2
    exit 1
  fi
fi

TMP_ROOT=""
cleanup() {
  if [ -n "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT"; fi
}
trap cleanup EXIT

is_elf() {
  [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

allowed() {
  local lib="$1" a
  for a in "${ALLOWLIST[@]}"; do
    if [ "$a" = "$lib" ]; then return 0; fi
  done
  # A here-string, not `printf | grep -q`: under pipefail an early grep exit
  # can SIGPIPE the writer and turn a match into a failure.
  [ "$HOST_MODE" -eq 1 ] && grep -qxF -- "$lib" <<<"$HOST_LIBS"
}

# Resolve each argument to a directory to walk: tarballs are unpacked into a
# scratch dir so the guard can run against exactly the artifact that ships.
ROOTS=()
LABELS=()

for p in "${PATHS[@]}"; do
  if [ -d "$p" ]; then
    norm="$p"
    while [ "$norm" != "/" ] && [ "${norm%/}" != "$norm" ]; do
      norm="${norm%/}"
    done
    ROOTS+=("$norm")
    LABELS+=("$p")
  elif [ -f "$p" ]; then
    case "$p" in
      *.tar.gz | *.tgz | *.tar)
        if [ -z "$TMP_ROOT" ]; then
          TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-release-shared-libs.XXXXXX")
        fi
        dest="$TMP_ROOT/$(printf '%s' "$p" | tr '/' '_')"
        mkdir -p "$dest"
        echo "Unpacking $p…"
        tar -xzf "$p" -C "$dest" 2>/dev/null || tar -xf "$p" -C "$dest"
        ROOTS+=("$dest")
        LABELS+=("$p")
        ;;
      *)
        echo "error: not a directory or a release tarball: $p" >&2
        exit 1
        ;;
    esac
  else
    echo "error: no such path: $p" >&2
    exit 1
  fi
done

scanned=0
offenders=0
unreadable=0

for i in "${!ROOTS[@]}"; do
  root="${ROOTS[$i]}"
  label="${LABELS[$i]}"

  echo "Scanning $label for shared-library dependencies…"

  while IFS= read -r -d '' file; do
    is_elf "$file" || continue

    scanned=$((scanned + 1))
    rel="${file#"$root"/}"

    if ! dyn=$(LC_ALL=C "$READELF" -d -W "$file" 2>&1) || grep -q 'Error:' <<<"$dyn"; then
      unreadable=$((unreadable + 1))
      printf '  %-10s %s\n' "UNREADABLE" "$rel"
      echo "ERROR: $rel is an ELF file readelf could not parse — cannot verify its dependencies" >&2
      continue
    fi

    needed=$(printf '%s\n' "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')

    bad=()
    while IFS= read -r lib; do
      [ -n "$lib" ] || continue
      allowed "$lib" || bad+=("$lib")
    done <<<"$needed"

    if [ ${#bad[@]} -eq 0 ]; then
      printf '  %-10s %s  (%s)\n' "ok" "$rel" "$(printf '%s' "$needed" | paste -sd, - | sed 's/,/, /g')"
      continue
    fi

    printf '  %-10s %s  <-- %s\n' "DISALLOWED" "$rel" "${bad[*]}"
    for lib in "${bad[@]}"; do
      offenders=$((offenders + 1))
      echo "ERROR: $rel needs $lib, which is not on the shared-library allowlist" >&2
    done
  done < <(find "$root" -type f -print0 | sort -z)
done

if [ "$scanned" -eq 0 ]; then
  echo "error: no ELF binaries found under: ${PATHS[*]}" >&2
  echo "       Refusing to report a vacuous pass — check the path." >&2
  exit 1
fi

echo
echo "Scanned $scanned ELF binaries against the allowlist: ${ALLOWLIST[*]}"
if [ "$HOST_MODE" -eq 1 ]; then
  echo "(--host: also accepting any library this host's loader resolves — not portable)"
fi

if [ "$unreadable" -gt 0 ]; then
  echo "FAIL: $unreadable ELF files could not be read." >&2
fi

if [ "$offenders" -gt 0 ]; then
  cat >&2 <<EOF

FAIL: $offenders disallowed shared-library dependencies.

A release carrying these cannot boot on a host that lacks the named library
(#1977: the crypto NIF needed libcrypto.so.1.1 and died on OpenSSL-3 hosts).
Link the dependency statically — for OpenSSL, build OTP with
scripts/build-release-otp.sh — rather than widening the allowlist.
EOF
fi

if [ "$unreadable" -gt 0 ] || [ "$offenders" -gt 0 ]; then
  exit 1
fi

echo "OK: every shipped binary depends only on allowlisted system libraries."
