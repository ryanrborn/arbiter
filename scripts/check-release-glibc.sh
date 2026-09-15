#!/usr/bin/env bash
# Refuse to ship an OTP release whose binaries need a newer glibc than the
# build image provides.
#
# Why this exists (bd-drjpmr / #1728): v0.1.64 could not boot on RHEL 8.10
# (glibc 2.28). The release workflow builds inside `redhat/ubi8`, which *is*
# glibc 2.28 — but `rustler_precompiled` DOWNLOADS the `mdex_native` NIF from
# upstream's GitHub releases at compile time instead of compiling it, so the
# build container's libc had no bearing on that one artifact. The prebuilt
# `.so` required symbols up to `GLIBC_2.34`, the loader refused it, `kernel`
# failed to start, the health check failed and the deploy auto-rolled back.
#
# Nothing in the Elixir build tells you that happened. This guard does: it
# reads the `GLIBC_x.y` symbol-version requests recorded in every shipped
# shared object / ELF binary and fails the build, naming the file, if any of
# them exceeds the baseline.
#
# Intentionally implemented with `grep` over the raw bytes rather than
# `readelf`/`objdump`: the version strings live in `.gnu.version_r` as plain
# NUL-terminated text, and this way the guard needs nothing but coreutils —
# it runs identically in the release container, in CI, and in the test suite.
# The trade-off is that a `GLIBC_` literal embedded in some *other* section
# would also be counted; that errs toward a red build, which is the safe
# direction here.
set -euo pipefail

# glibc of the release build image (redhat/ubi8) == glibc of the oldest host
# we support. Keep in sync with the container in .github/workflows/release.yml.
DEFAULT_BASELINE="2.28"

usage() {
  cat <<'USAGE'
Usage: scripts/check-release-glibc.sh [--baseline X.Y] <path>...

  <path>   An assembled release directory (e.g. _build/prod/rel/arbiter) or a
           release tarball (.tar.gz / .tgz / .tar). May be repeated.

  --baseline X.Y
           Highest glibc symbol version a shipped binary is allowed to
           require. Defaults to 2.28, the glibc of the `redhat/ubi8` release
           build image and of the oldest supported host (RHEL 8).

Scans every shared object (*.so, *.so.*) and every other ELF file under each
path, and reports the highest `GLIBC_*` symbol version each one requires.

Exit status:
  0  every binary stays at or below the baseline
  1  at least one binary exceeds it (each offender is named), or the scan
     found nothing to check / the arguments were wrong

Examples:
  scripts/check-release-glibc.sh _build/prod/rel/arbiter
  scripts/check-release-glibc.sh arbiter-v0.1.65-linux.tar.gz
  scripts/check-release-glibc.sh --baseline 2.34 _build/prod/rel/arbiter
USAGE
}

BASELINE="$DEFAULT_BASELINE"
PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --baseline)
      if [ -z "${2:-}" ]; then
        echo "error: --baseline needs a value (e.g. --baseline 2.28)" >&2
        exit 1
      fi
      BASELINE="$2"
      shift 2
      ;;
    --baseline=*)
      BASELINE="${1#--baseline=}"
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

if ! printf '%s' "$BASELINE" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
  echo "error: --baseline must look like 2.28, got: $BASELINE" >&2
  exit 1
fi

TMP_ROOT=""
cleanup() {
  if [ -n "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT"; fi
}
trap cleanup EXIT

# Highest of two dotted versions, compared numerically (`sort -V`) — a lexical
# compare would rank 2.9 above 2.28 and wave the real offenders through.
max_version() {
  printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1
}

# Highest GLIBC_ symbol version a single file requires, or "" if it asks for
# none (statically linked, non-glibc, or not a real binary).
glibc_requirement() {
  grep -aoE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' "$1" 2>/dev/null |
    sed 's/^GLIBC_//' |
    sort -V |
    tail -n 1 ||
    true
}

is_elf() {
  [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

# Resolve each argument to a directory to walk: tarballs are unpacked into a
# scratch dir so the guard can run against exactly the artifact that ships.
ROOTS=()
LABELS=()

for p in "${PATHS[@]}"; do
  if [ -d "$p" ]; then
    ROOTS+=("$p")
    LABELS+=("$p")
  elif [ -f "$p" ]; then
    case "$p" in
      *.tar.gz | *.tgz | *.tar)
        if [ -z "$TMP_ROOT" ]; then
          TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-release-glibc.XXXXXX")
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
highest="0.0"

for i in "${!ROOTS[@]}"; do
  root="${ROOTS[$i]}"
  label="${LABELS[$i]}"

  echo "Scanning $label (glibc baseline $BASELINE)…"

  while IFS= read -r -d '' file; do
    case "$file" in
      *.so | *.so.*) ;;
      *)
        is_elf "$file" || continue
        ;;
    esac

    scanned=$((scanned + 1))
    required=$(glibc_requirement "$file")
    rel="${file#"$root"/}"

    if [ -z "$required" ]; then
      printf '  %-8s %s\n' "-" "$rel"
      continue
    fi

    highest=$(max_version "$highest" "$required")

    if [ "$(max_version "$BASELINE" "$required")" != "$BASELINE" ]; then
      offenders=$((offenders + 1))
      printf '  %-8s %s  <-- TOO NEW\n' "$required" "$rel"
      echo "ERROR: $rel requires GLIBC_$required, above the $BASELINE baseline" >&2
    else
      printf '  %-8s %s\n' "$required" "$rel"
    fi
  done < <(find "$root" -type f -print0 | sort -z)
done

if [ "$scanned" -eq 0 ]; then
  echo "error: no shared objects or ELF binaries found under: ${PATHS[*]}" >&2
  echo "       Refusing to report a vacuous pass — check the path." >&2
  exit 1
fi

echo
echo "Scanned $scanned binaries; highest required glibc: $highest (baseline $BASELINE)."

if [ "$offenders" -gt 0 ]; then
  cat >&2 <<EOF

FAIL: $offenders binaries require a glibc newer than $BASELINE.

This release cannot boot on the oldest supported host. If the offender is a
Rust NIF, it was almost certainly *downloaded* as a precompiled artifact
instead of built in this container — force a source build, e.g. by exporting
RUSTLER_PRECOMPILED_FORCE_BUILD_ALL=1 (needs a Rust toolchain) — and rebuild.
EOF
  exit 1
fi

echo "OK: every shipped binary loads on glibc $BASELINE."
